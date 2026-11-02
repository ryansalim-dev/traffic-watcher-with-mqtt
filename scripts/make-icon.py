#!/usr/bin/env python3
"""Draws Wiretide's app icon and writes Packaging/AppIcon.iconset (PNG sizes iconutil expects).

Graphite squircle on Apple's 1024 pt icon grid, with the tide wave from the app's setup screen:
a dim back wave, a bright teal front wave, and a captured packet riding its crest.
Requires Pillow. build-app.sh turns the iconset into AppIcon.icns with iconutil on macOS.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SCALE = 4                      # supersampling factor
S = 1024 * SCALE
BODY = (100 * SCALE, 100 * SCALE, 924 * SCALE, 924 * SCALE)  # macOS icon grid: 824 pt body
RADIUS = 185 * SCALE

TOP, BOTTOM = (46, 53, 60), (17, 20, 24)        # graphite, as in the app's dark theme
TEAL, TEAL_DEEP = (79, 209, 197), (11, 141, 135)  # Theme.accent dark / light


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def squircle_mask():
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(BODY, RADIUS, fill=255)
    return mask


def vertical_gradient(top, bottom):
    column = Image.new("RGB", (1, S))
    for y in range(S):
        column.putpixel((0, y), lerp(top, bottom, y / (S - 1)))
    return column.resize((S, S))


def wave_points(baseline, amplitude, phase=0.0, cycles=1.25, steps=1600):
    x0, x1 = BODY[0] - 60 * SCALE, BODY[2] + 60 * SCALE
    points = []
    for i in range(steps + 1):
        t = i / steps
        x = x0 + (x1 - x0) * t
        y = baseline - amplitude * math.sin(t * math.pi * 2 * cycles + phase)
        points.append((x, y))
    return points


def stroke(points, width, fill):
    """A round-capped stroke drawn by stamping discs, which stays smooth on tight curves."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    r = width / 2
    for x, y in points:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)
    return layer


def draw():
    mask = squircle_mask()
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Soft shadow under the body, as on Apple's own icons.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: v * 0.45))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -12 * SCALE)).filter(ImageFilter.GaussianBlur(14 * SCALE))
    art.alpha_composite(shadow)

    body = vertical_gradient(TOP, BOTTOM).convert("RGBA")
    # A faint teal glow rising from the bottom, where the water is.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((150 * SCALE, 560 * SCALE, 874 * SCALE, 1180 * SCALE), fill=TEAL + (70,))
    body.alpha_composite(glow.filter(ImageFilter.GaussianBlur(120 * SCALE)))

    # Waves.
    # The front wave peaks at 62% across, where the packet sits.
    phase = math.pi / 2 - 0.62 * 2 * math.pi * 1.25
    back = wave_points(650 * SCALE, 80 * SCALE, phase=phase - 1.1)
    body.alpha_composite(stroke(back, 46 * SCALE, TEAL + (95,)))
    front_points = wave_points(540 * SCALE, 130 * SCALE, phase=phase)
    front = stroke(front_points, 70 * SCALE, (255, 255, 255, 255))
    # Teal gradient along the front wave: deep on the left, bright on the right.
    shade = Image.new("RGBA", (S, S))
    row = Image.new("RGBA", (S, 1))
    for x in range(S):
        row.putpixel((x, 0), lerp(TEAL_DEEP, TEAL, x / (S - 1)) + (255,))
    shade = row.resize((S, S))
    shade.putalpha(front.getchannel("A"))
    body.alpha_composite(shade)

    # The captured packet on the crest, with a halo.
    crest = min(front_points, key=lambda p: p[1] if 300 * SCALE < p[0] < 800 * SCALE else 1e9)
    cx, cy = crest
    halo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((cx - 120 * SCALE, cy - 120 * SCALE, cx + 120 * SCALE, cy + 120 * SCALE), fill=TEAL + (120,))
    body.alpha_composite(halo.filter(ImageFilter.GaussianBlur(40 * SCALE)))
    r = 58 * SCALE
    dot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse((cx - r, cy - r, cx + r, cy + r), fill=(236, 255, 252, 255))
    body.alpha_composite(dot)
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((cx - r, cy - r, cx + r, cy + r), outline=TEAL_DEEP + (255,), width=10 * SCALE)
    body.alpha_composite(ring)

    # Thin top highlight on the rim.
    rim = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rim).rounded_rectangle(BODY, RADIUS, outline=255, width=3 * SCALE)
    fade = Image.linear_gradient("L").resize((S, S)).point(lambda v: 255 - v)
    rim = ImageChops.multiply(rim, fade).point(lambda v: v * 0.35)
    highlight = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    highlight.putalpha(rim)
    body.alpha_composite(highlight)

    body.putalpha(ImageChops.multiply(body.getchannel("A"), mask))
    art.alpha_composite(body)
    return art.resize((1024, 1024), Image.LANCZOS)


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    master = draw()
    for size in (16, 32, 128, 256, 512):
        master.resize((size, size), Image.LANCZOS).save(os.path.join(out_dir, f"icon_{size}x{size}.png"))
        master.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(out_dir, f"icon_{size}x{size}@2x.png"))
    print(out_dir)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Packaging", "AppIcon.iconset"))
