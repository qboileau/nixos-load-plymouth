{
  description = "NixOS Plymouth boot splash themes — progressive lambda reveal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Source SVG filename for each variant
      sourcesvgs = {
        default = "nixos-logo-default-gradient-white-regular-vertical-recommended.svg";
        rainbow = "nixos-logo-rainbow-gradient-white-regular-vertical-recommended.svg";
        white   = "nixos-logo-white-flat-white-regular-vertical-recommended.svg";
      };

      # Build rasterized frames from a source SVG.
      # Splits the logo into 6 individual lambda PNGs + text PNG.
      mkFrames = pkgs: variant:
        pkgs.runCommand "nixos-loading-frames-${variant}" {
          nativeBuildInputs = [ pkgs.python3 pkgs.librsvg ];
        } ''
          mkdir -p "$out"
          python3 ${./generate-frames.py} \
            "${./assets}/${sourcesvgs.${variant}}" "$out"
        '';

      # Shared builder: takes a variant name ("default", "rainbow", "white")
      # and produces a Plymouth theme derivation.
      # Uses pre-rasterized PNGs from frames/ — no build-time SVG tooling.
      mkTheme = pkgs: variant:
        pkgs.stdenv.mkDerivation {
          pname = "nixos-loading-plymouth-${variant}";
          version = "0.1.0";
          src = ./.;

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            themedir=$out/share/plymouth/themes/nixos-loading-${variant}
            mkdir -p "$themedir"

            # Copy pre-rasterized PNGs
            cp frames/${variant}/*.png "$themedir/"

            # Install Plymouth script
            cp theme/nixos-loading.script "$themedir/"

            # Install .plymouth config with store path substituted
            substitute theme/nixos-loading.plymouth \
              "$themedir/nixos-loading-${variant}.plymouth" \
              --replace-fail '@themedir@' "$themedir"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "NixOS Plymouth theme (${variant}) with progressive lambda reveal";
            license = licenses.mit;
            platforms = platforms.linux;
          };
        };

      # GIF preview builder for a variant
      mkPreview = pkgs: variant:
        pkgs.runCommand "nixos-loading-preview-${variant}" {
          nativeBuildInputs = [ pkgs.imagemagick ];
        } ''
          mkdir -p "$out" work

          # Use pre-rasterized frames
          cp ${./frames}/${variant}/*.png work/

          # Canvas size
          W=640
          H=480

          # Reveal order (clockwise from top-left): 3 4 5 6 1 2
          order="3 4 5 6 1 2"

          # Frame 0: just text on dark background
          convert -size ''${W}x''${H} xc:"#191924" \
            work/text.png -gravity center -geometry +0+120 -composite \
            work/frame-0.png

          # Frames 1-6: progressively add lambdas
          n=0
          prev="work/frame-0.png"
          for idx in $order; do
            n=$((n + 1))
            convert "$prev" \
              "work/lambda-$idx.png" -gravity center -geometry +0-60 -composite \
              "work/frame-$n.png"
            prev="work/frame-$n.png"
          done

          # Frames 7-12: progressively remove lambdas (same order)
          n=6
          for idx in $order; do
            n=$((n + 1))
            removed=$((n - 6))
            cmd="convert -size ''${W}x''${H} xc:\"#191924\" work/text.png -gravity center -geometry +0+120 -composite"
            count=0
            for idx2 in $order; do
              count=$((count + 1))
              if [ $count -gt $removed ]; then
                cmd="$cmd work/lambda-$idx2.png -gravity center -geometry +0-60 -composite"
              fi
            done
            eval "$cmd work/frame-$n.png"
          done

          # Assemble animated GIF (500ms per frame, last frame holds 1.5s)
          delays=""
          for f in $(seq 0 11); do
            delays="$delays -delay 50 work/frame-$f.png"
          done
          convert $delays -delay 150 work/frame-12.png \
            -loop 0 "$out/preview-${variant}.gif"
        '';
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nixos-loading-default = mkTheme pkgs "default";
          nixos-loading-rainbow = mkTheme pkgs "rainbow";
          nixos-loading-white   = mkTheme pkgs "white";

          # Default package is the blue gradient variant
          default = mkTheme pkgs "default";

          # Rasterized frames (for CI/regeneration)
          frames-default = mkFrames pkgs "default";
          frames-rainbow = mkFrames pkgs "rainbow";
          frames-white   = mkFrames pkgs "white";

          # Preview GIFs
          preview-default = mkPreview pkgs "default";
          preview-rainbow = mkPreview pkgs "rainbow";
          preview-white   = mkPreview pkgs "white";
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python3      # SVG splitting in generate-frames.sh
              librsvg      # rsvg-convert for SVG → PNG rasterization
              imagemagick  # convert for GIF preview generation
              plymouth     # local theme testing
            ];
          };
        }
      );

      # NixOS module — configurable variant
      nixosModules.default = { config, pkgs, lib, ... }:
        let
          cfg = config.boot.plymouth.nixos-loading;
        in
        {
          options.boot.plymouth.nixos-loading = {
            enable = lib.mkEnableOption "NixOS loading Plymouth theme";
            variant = lib.mkOption {
              type = lib.types.enum [ "default" "rainbow" "white" ];
              default = "default";
              description = "NixOS loading Plymouth theme color variant.";
            };
          };

          config = lib.mkIf cfg.enable {
            boot.plymouth = {
              enable = true;
              theme = "nixos-loading-${cfg.variant}";
              themePackages = [
                self.packages.${pkgs.stdenv.hostPlatform.system}."nixos-loading-${cfg.variant}"
              ];
            };
          };
        };
    };
}
