#!/usr/bin/env bash
# Test the NixOS Loading Plymouth theme using pre-rasterized PNGs from frames/.
# Run ./generate-frames.py first to produce the PNGs.
#
# By default cycles through all three variants (default, rainbow, white)
# for 5 seconds each (15 seconds total).
#
# Prerequisites: run from a real TTY inside `nix develop`
#
# Usage (from within nix develop):
#   sudo -E env PATH="$PATH" ./test-plymouth.sh [variant|all] [total-seconds]
#
# Variants: default, rainbow, white, all (defaults to "all")
# Seconds:  total display time across all variants (defaults to 15, max 60)
#
# Recovery if screen goes black:
#   Ctrl+Alt+F2 → sudo plymouth quit && sudo killall plymouthd
#   Ctrl+Alt+F1 → back to your session

set -euo pipefail

VARIANT="${1:-all}"
DURATION="${2:-15}"

VARIANTS=()
if [[ "$VARIANT" == "all" ]]; then
  VARIANTS=(default rainbow white)
elif [[ "$VARIANT" == "default" || "$VARIANT" == "rainbow" || "$VARIANT" == "white" ]]; then
  VARIANTS=("$VARIANT")
else
  echo "Error: unknown variant '$VARIANT'. Choose: default, rainbow, white, all"
  exit 1
fi

if [[ "$DURATION" -gt 60 ]]; then
  DURATION=60
fi

PER_VARIANT=$((DURATION / ${#VARIANTS[@]}))
if [[ "$PER_VARIANT" -lt 1 ]]; then
  PER_VARIANT=1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root."
  echo "Usage: sudo -E env PATH=\"\$PATH\" ./test-plymouth.sh [variant] [seconds]"
  exit 1
fi

# Resolve repo root (where this script lives)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
for cmd in plymouthd plymouth; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' not found. Run this from within 'nix develop'."
    exit 1
  fi
done

# Verify frames exist for requested variants
for v in "${VARIANTS[@]}"; do
  if [[ ! -d "$REPO_DIR/frames/$v" ]]; then
    echo "Error: frames/$v/ not found. Run './generate-frames.py $v' first."
    exit 1
  fi
done

# ── Locate Plymouth's compiled-in paths ──────────────────────────────
THEME_SETTER="$(command -v plymouth-set-default-theme)"
PLYMOUTH_DATADIR=$(grep -oP '(?<=PLYMOUTH_DATADIR=")[^"]+' "$THEME_SETTER" | head -1)
PLYMOUTH_CONFDIR=$(grep -oP '(?<=PLYMOUTH_CONFDIR=")[^"]+' "$THEME_SETTER" | head -1)
PLYMOUTH_THEMES_DIR="$PLYMOUTH_DATADIR/plymouth/themes"

echo "==> Plymouth themes dir: $PLYMOUTH_THEMES_DIR"
echo "==> Plymouth config dir: $PLYMOUTH_CONFDIR"

# ── Determine TTY ───────────────────────────────────────────────────
CURRENT_TTY=$(tty 2>/dev/null || echo "/dev/tty1")
if [[ "$CURRENT_TTY" == "not a tty" ]]; then
  CURRENT_TTY="/dev/tty1"
fi

# ── Install overlays (once for the whole run) ────────────────────────
OVERLAY_UPPER=$(mktemp -d)
OVERLAY_WORK=$(mktemp -d)
CONF_OVERLAY_UPPER=$(mktemp -d)
CONF_OVERLAY_WORK=$(mktemp -d)
TMPDIR_BUILD=$(mktemp -d -t plymouth-build.XXXXXX)

cleanup() {
  echo "==> Cleaning up"
  plymouth quit 2>/dev/null || true
  killall plymouthd 2>/dev/null || true
  umount "$PLYMOUTH_CONFDIR" 2>/dev/null || true
  umount "$PLYMOUTH_THEMES_DIR" 2>/dev/null || true
  rm -rf "$OVERLAY_UPPER" "$OVERLAY_WORK" "$CONF_OVERLAY_UPPER" "$CONF_OVERLAY_WORK" "$TMPDIR_BUILD"
}
trap cleanup EXIT

echo "==> Mounting overlay on $PLYMOUTH_THEMES_DIR"
mount -t overlay overlay \
  -o "lowerdir=$PLYMOUTH_THEMES_DIR,upperdir=$OVERLAY_UPPER,workdir=$OVERLAY_WORK" \
  "$PLYMOUTH_THEMES_DIR"

echo "==> Mounting overlay on $PLYMOUTH_CONFDIR"
mount -t overlay overlay \
  -o "lowerdir=$PLYMOUTH_CONFDIR,upperdir=$CONF_OVERLAY_UPPER,workdir=$CONF_OVERLAY_WORK" \
  "$PLYMOUTH_CONFDIR"

# ── Cycle through variants ──────────────────────────────────────────
echo "==> Testing ${#VARIANTS[@]} variant(s): ${VARIANTS[*]} (${PER_VARIANT}s each, ${DURATION}s total)"
echo "    Recovery: Ctrl+Alt+F2 → sudo plymouth quit && sudo killall plymouthd"

for v in "${VARIANTS[@]}"; do
  THEME_NAME="nixos-loading-${v}"
  THEME_INSTALL_DIR="$PLYMOUTH_THEMES_DIR/$THEME_NAME"

  # Copy pre-rasterized PNGs for this variant
  echo "==> Installing variant: $v"
  rm -rf "$TMPDIR_BUILD"/*
  cp "$REPO_DIR/frames/${v}/"*.png "$TMPDIR_BUILD/"

  cp "$REPO_DIR/theme/nixos-loading.script" "$TMPDIR_BUILD/"
  sed "s|@themedir@|$THEME_INSTALL_DIR|g" \
    "$REPO_DIR/theme/nixos-loading.plymouth" \
    > "$TMPDIR_BUILD/${THEME_NAME}.plymouth"

  # Install theme into the overlay
  rm -rf "$THEME_INSTALL_DIR"
  cp -r "$TMPDIR_BUILD" "$THEME_INSTALL_DIR"

  # Update plymouthd.conf
  cat > "$PLYMOUTH_CONFDIR/plymouthd.conf" <<EOF
[Daemon]
Theme=$THEME_NAME
ShowDelay=0
EOF

  # Start Plymouth for this variant
  echo "==> Starting Plymouth: $THEME_NAME (${PER_VARIANT}s)"
  plymouthd --tty="$CURRENT_TTY" --mode=boot
  sleep 0.5
  plymouth show-splash
  plymouth display-message --text="Testing: $THEME_NAME (${PER_VARIANT}s)" 2>/dev/null || true

  sleep "$PER_VARIANT"

  # Stop Plymouth before next variant
  plymouth quit 2>/dev/null || true
  killall plymouthd 2>/dev/null || true
  sleep 0.5
done

echo "Done!"
