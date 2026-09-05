#!/usr/bin/env python3
"""Render the three AppIcon PNGs in App/Assets.xcassets/AppIcon.appiconset/
from AppIcon.svg, per Apple's iOS 18 light/dark/tinted icon guidance.

  python scripts/render_app_icon.py base    # AppIcon-1024.png (opaque, white bg)
  python scripts/render_app_icon.py dark    # AppIcon-1024-dark.png (transparent bg)
  python scripts/render_app_icon.py tinted  # AppIcon-1024-tinted.png (transparent bg)
  python scripts/render_app_icon.py all     # all three

Needs cairosvg and Pillow (`pip install cairosvg Pillow`).

Dark and tinted drop the background to fully transparent, because Apple paints
its own backdrop behind them. Dark lifts the violet accent (#6C3FD1 in the base
icon) to #8F6EFF, the SharedAssets dark accent, and lifts the near-black strokes
and bars (#1C1B1F) to white, which would otherwise vanish against Apple's dark
gradient. Tinted holds the whole glyph grayscale (R==G==B) so Apple recolors it
by luminance: the two dominant masses, the messy strokes and the four-bar list,
sit near white, and the small connecting arrow sits mid-gray behind them.
"""
import io
import os
import sys
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image

ICONSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "App", "Assets.xcassets", "AppIcon.appiconset",
)
SVG_PATH = os.path.join(ICONSET_DIR, "AppIcon.svg")
SVG_NAMESPACE = "http://www.w3.org/2000/svg"

# AppIcon.svg draws the background rect first, then these shapes in this order.
# The arrow and the first list bar carry the same source hex but take different
# tinted colors, so each shape takes its color by position, not by hex.
SHAPE_ROLES = ("messy", "arrow", "arrow", "bar1", "bar", "bar", "bar")


def build_glyph_svg(colors):
    """Return AppIcon.svg without its background rect, each shape recolored."""
    ET.register_namespace("", SVG_NAMESPACE)
    root = ET.parse(SVG_PATH).getroot()
    background, *shapes = list(root)
    if len(shapes) != len(SHAPE_ROLES):
        sys.exit(f"AppIcon.svg draws {len(shapes)} shapes, SHAPE_ROLES names {len(SHAPE_ROLES)}")
    root.remove(background)
    for shape, role in zip(shapes, SHAPE_ROLES):
        for attribute in ("fill", "stroke"):
            if shape.get(attribute) not in (None, "none"):
                shape.set(attribute, colors[role])
    return ET.tostring(root, encoding="unicode")


def render_transparent(colors, filename):
    svg = build_glyph_svg(colors)
    png = cairosvg.svg2png(bytestring=svg.encode("utf-8"), output_width=1024, output_height=1024)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    im.save(os.path.join(ICONSET_DIR, filename))
    print(f"wrote {filename}")


def render_base():
    png = cairosvg.svg2png(url=SVG_PATH, output_width=1024, output_height=1024)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    bg = Image.new("RGB", im.size, "#FFFFFF")
    bg.paste(im, mask=im.split()[3])
    bg.save(os.path.join(ICONSET_DIR, "AppIcon-1024.png"))
    print("wrote AppIcon-1024.png")


def render_dark():
    render_transparent(
        {"messy": "#FFFFFF", "arrow": "#8F6EFF", "bar1": "#8F6EFF", "bar": "#FFFFFF"},
        "AppIcon-1024-dark.png",
    )


def render_tinted():
    render_transparent(
        {"messy": "#F2F2F2", "arrow": "#808080", "bar1": "#F2F2F2", "bar": "#F2F2F2"},
        "AppIcon-1024-tinted.png",
    )


MODES = {"base": render_base, "dark": render_dark, "tinted": render_tinted}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    if mode == "all":
        for fn in MODES.values():
            fn()
        return
    if mode not in MODES:
        sys.exit(f"unknown mode {mode!r}; expected one of {list(MODES)} or 'all'")
    MODES[mode]()


if __name__ == "__main__":
    main()
