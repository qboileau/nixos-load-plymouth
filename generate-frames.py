#!/usr/bin/env python3
"""Extract individual lambda arms and NixOS text from a source logo SVG,
then rasterize them to PNG using CairoSVG (pure Python, no rsvg-convert).

The resulting PNGs are stored in frames/<variant>/ and committed to the
repository so the theme can be packaged without build-time SVG tooling.

Usage:
    ./generate-frames.py                        # all variants
    ./generate-frames.py default                # single variant
    ./generate-frames.py /path/to/logo.svg out/ # raw split+rasterize mode
"""

import copy
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

NS = "http://www.w3.org/2000/svg"

LAMBDA_VIEWBOX = "-1200 -1050 2400 2100"
TEXT_VIEWBOX = "-10 -1366 4486 1401"

LAMBDA_WIDTH = 512
TEXT_WIDTH = 256

SOURCE_SVGS = {
    "default": "nixos-logo-default-gradient-white-regular-vertical-recommended.svg",
    "rainbow": "nixos-logo-rainbow-gradient-white-regular-vertical-recommended.svg",
    "white": "nixos-logo-white-flat-white-regular-vertical-recommended.svg",
}


def _make_svg(viewbox: str) -> ET.Element:
    """Create an SVG root element with the given viewBox.
    
    We write the xmlns attribute manually in the serialization step
    to avoid ElementTree's duplicate namespace issue with rsvg-convert.
    """
    svg = ET.Element("svg")
    svg.set("viewBox", viewbox)
    return svg


def _write_svg(tree: ET.ElementTree, path: str) -> None:
    """Write SVG tree, injecting the xmlns declaration."""
    raw = ET.tostring(tree.getroot(), encoding="unicode")
    # Inject xmlns if not present (ElementTree drops it without register_namespace)
    if 'xmlns="' not in raw:
        raw = raw.replace("<svg ", f'<svg xmlns="{NS}" ', 1)
    with open(path, "w") as f:
        f.write(raw)


def split_svg(source_svg: str, output_dir: str) -> None:
    """Split a NixOS logo SVG into 6 lambda SVGs + 1 text SVG."""
    tree = ET.parse(source_svg)
    root = tree.getroot()

    # Collect gradient definitions (may be empty for "white" variant)
    defs_elem = root.find(f"{{{NS}}}defs")
    gradients = {}
    if defs_elem is not None:
        for grad in defs_elem.findall(f"{{{NS}}}linearGradient"):
            gradients[grad.get("id")] = grad

    # Extract each polygon (lambda arm)
    polygons = root.findall(f"{{{NS}}}polygon")
    for i, polygon in enumerate(polygons):
        svg = _make_svg(LAMBDA_VIEWBOX)

        new_polygon = copy.deepcopy(polygon)
        fill = polygon.get("fill", "")

        if fill.startswith("url(#"):
            grad_id = fill[5:-1]
            if grad_id in gradients:
                new_defs = ET.SubElement(svg, "defs")
                new_grad = copy.deepcopy(gradients[grad_id])
                new_grad.set("id", "grad")
                new_defs.append(new_grad)
                new_polygon.set("fill", "url(#grad)")

        svg.append(new_polygon)

        out_path = os.path.join(output_dir, f"lambda-{i + 1}.svg")
        _write_svg(ET.ElementTree(svg), out_path)
        print(f"  Extracted: lambda-{i + 1}.svg")

    # Extract text (the <g> with <path> children)
    g_elem = root.find(f"{{{NS}}}g")
    if g_elem is not None:
        svg = _make_svg(TEXT_VIEWBOX)

        for path in g_elem.findall(f"{{{NS}}}path"):
            svg.append(copy.deepcopy(path))

        out_path = os.path.join(output_dir, "text.svg")
        _write_svg(ET.ElementTree(svg), out_path)
        print("  Extracted: text.svg")


def rasterize(svg_path: str, png_path: str, width: int) -> None:
    """Rasterize an SVG to PNG using rsvg-convert."""
    subprocess.run(
        ["rsvg-convert", "-w", str(width), svg_path, "-o", png_path],
        check=True,
    )


def process_variant(variant: str, assets_dir: str, frames_dir: str) -> None:
    """Split source SVG and rasterize to PNGs for one variant."""
    source_svg = os.path.join(assets_dir, SOURCE_SVGS[variant])
    if not os.path.isfile(source_svg):
        print(f"Error: source SVG not found: {source_svg}", file=sys.stderr)
        sys.exit(1)

    output_dir = os.path.join(frames_dir, variant)
    os.makedirs(output_dir, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        print(f"==> Splitting {variant} source SVG into components")
        split_svg(source_svg, tmp)

        print(f"==> Rasterizing PNGs for: {variant}")
        for i in range(1, 7):
            rasterize(
                os.path.join(tmp, f"lambda-{i}.svg"),
                os.path.join(output_dir, f"lambda-{i}.png"),
                LAMBDA_WIDTH,
            )
        rasterize(
            os.path.join(tmp, "text.svg"),
            os.path.join(output_dir, "text.png"),
            TEXT_WIDTH,
        )

    print(f"==> Done: {output_dir}/")
    print("   ", " ".join(sorted(os.listdir(output_dir))))


def main() -> None:
    # Raw mode: generate-frames.py <source.svg> <output_dir>
    # Used by Nix mkFrames derivation.
    if len(sys.argv) == 3 and sys.argv[1].endswith(".svg"):
        source_svg = sys.argv[1]
        output_dir = sys.argv[2]
        os.makedirs(output_dir, exist_ok=True)

        with tempfile.TemporaryDirectory() as tmp:
            print(f"==> Splitting {os.path.basename(source_svg)}")
            split_svg(source_svg, tmp)

            print("==> Rasterizing PNGs")
            for i in range(1, 7):
                rasterize(
                    os.path.join(tmp, f"lambda-{i}.svg"),
                    os.path.join(output_dir, f"lambda-{i}.png"),
                    LAMBDA_WIDTH,
                )
            rasterize(
                os.path.join(tmp, "text.svg"),
                os.path.join(output_dir, "text.png"),
                TEXT_WIDTH,
            )
        print(f"==> Done: {output_dir}/")
        return

    # Check rsvg-convert is available
    if not shutil.which("rsvg-convert"):
        print("Error: 'rsvg-convert' not found. Run from within 'nix develop'.",
              file=sys.stderr)
        sys.exit(1)

    # Variant mode: generate-frames.py [variant ...]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    assets_dir = os.path.join(script_dir, "assets")
    frames_dir = os.path.join(script_dir, "frames")

    variants = sys.argv[1:] if len(sys.argv) > 1 else list(SOURCE_SVGS.keys())

    for v in variants:
        if v not in SOURCE_SVGS:
            print(f"Error: unknown variant '{v}'. "
                  f"Choose: {', '.join(SOURCE_SVGS.keys())}", file=sys.stderr)
            sys.exit(1)

    for v in variants:
        process_variant(v, assets_dir, frames_dir)


if __name__ == "__main__":
    main()
