{
  description = "NixOS Plymouth boot splash themes — progressive lambda reveal";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Shared builder: takes a variant name ("default", "rainbow", "white")
      # and produces a Plymouth theme derivation.
      mkTheme = pkgs: variant:
        pkgs.stdenv.mkDerivation {
          pname = "nixos-loading-plymouth-${variant}";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.librsvg ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            themedir=$out/share/plymouth/themes/nixos-loading-${variant}
            mkdir -p "$themedir"

            # Rasterize each lambda SVG to PNG (512 px wide, height auto)
            for i in 1 2 3 4 5 6; do
              rsvg-convert -w 512 "assets/${variant}/lambda-$i.svg" \
                -o "$themedir/lambda-$i.png"
            done

            # Rasterize shared NixOS wordmark text
            rsvg-convert -w 256 "assets/text.svg" \
              -o "$themedir/text.png"

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
          nativeBuildInputs = [ pkgs.librsvg pkgs.imagemagick ];
        } ''
          mkdir -p "$out" work

          # Rasterize assets
          rsvg-convert -w 256 "${./assets/text.svg}" -o work/text.png
          for i in 1 2 3 4 5 6; do
            rsvg-convert -w 256 "${./assets}/${variant}/lambda-$i.svg" \
              -o "work/lambda-$i.png"
          done

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

          # Assemble animated GIF (500ms per frame, last frame holds 1.5s)
          delays=""
          for f in 0 1 2 3 4 5; do
            delays="$delays -delay 50 work/frame-$f.png"
          done
          convert $delays -delay 150 work/frame-6.png \
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
              librsvg      # rsvg-convert for SVG → PNG
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
