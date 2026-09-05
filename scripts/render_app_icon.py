#!/usr/bin/env python3
"""Render the three AppIcon PNGs in App/Assets.xcassets/AppIcon.appiconset/
from AppIcon.svg, per Apple's iOS 18 light/dark/tinted icon guidance.

  python scripts/render_app_icon.py base    # AppIcon-1024.png (opaque, white bg)
  python scripts/render_app_icon.py dark    # AppIcon-1024-dark.png (transparent bg)
  python scripts/render_app_icon.py tinted  # AppIcon-1024-tinted.png (transparent bg)
  python scripts/render_app_icon.py all     # all three

Needs cairosvg and Pillow (`pip install cairosvg Pillow`).

The glyph geometry below (the messy-strokes lines, the arrow, the four list
bars) mirrors AppIcon.svg's shapes exactly; if that file's coordinates ever
change, update the constants here to match before re-running dark/tinted.

Color choices:
  dark:   background dropped to fully transparent (Apple paints its own dark
          gradient behind it). The violet accent (#6C3FD1 in the base icon)
          lifts to #8F6EFF, matching SharedAssets' dark-mode accent. The
          near-black strokes/bars (#1C1B1F) lift to white, since they would
          be invisible against a dark background.
  tinted: background dropped to fully transparent; the whole glyph is
          grayscale (R==G==B) so Apple's tint recolors it by luminance. The
          two dominant masses -- the messy strokes and the four-bar list --
          sit near white as the "main" strokes; the small connecting arrow
          sits mid-gray as the "secondary" detail.
"""
import io
import os
import sys

import cairosvg
from PIL import Image

ICONSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "App", "Assets.xcassets", "AppIcon.appiconset",
)
SVG_PATH = os.path.join(ICONSET_DIR, "AppIcon.svg")

MESSY_LINES = """
  <g stroke="{messy}" stroke-width="58" stroke-linecap="round" fill="none">
    <line x1="215" y1="215" x2="430" y2="150"/>
    <line x1="300" y1="205" x2="430" y2="285"/>
    <line x1="135" y1="350" x2="305" y2="450"/>
    <line x1="320" y1="380" x2="480" y2="340"/>
  </g>
"""

ARROW = """
  <line x1="515" y1="445" x2="548" y2="498" stroke="{arrow}" stroke-width="40" stroke-linecap="round"/>
  <polygon points="597,547 579,466 516,529" fill="{arrow}"/>
"""

LIST = """
  <rect x="490" y="560" width="421" height="57" rx="28.5" fill="{bar1}"/>
  <rect x="490" y="664" width="421" height="57" rx="28.5" fill="{barrest}"/>
  <rect x="490" y="768" width="421" height="57" rx="28.5" fill="{barrest}"/>
  <rect x="490" y="872" width="321" height="57" rx="28.5" fill="{barrest}"/>
"""

SVG_TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
{messy}
{arrow}
{list}
</svg>"""


def build_svg(messy, arrow, bar1, barrest):
    return SVG_TEMPLATE.format(
        messy=MESSY_LINES.format(messy=messy),
        arrow=ARROW.format(arrow=arrow),
        list=LIST.format(bar1=bar1, barrest=barrest),
    )


def render_transparent(svg_text, filename):
    png_bytes = cairosvg.svg2png(bytestring=svg_text.encode("utf-8"), output_width=1024, output_height=1024)
    im = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
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
    svg = build_svg(messy="#FFFFFF", arrow="#8F6EFF", bar1="#8F6EFF", barrest="#FFFFFF")
    render_transparent(svg, "AppIcon-1024-dark.png")


def render_tinted():
    svg = build_svg(messy="#F2F2F2", arrow="#808080", bar1="#F2F2F2", barrest="#F2F2F2")
    render_transparent(svg, "AppIcon-1024-tinted.png")


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
