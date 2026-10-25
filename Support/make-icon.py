"""Daftar.icns from art/icon.png, the logo of Daftar on Android.

The logo is a rounded square on a white margin. macOS draws an app icon as an
824-pixel rounded square in a 1024 canvas with transparent space around it,
so the logo is cropped a little inside its own corners, masked to that shape
and centred.  Run with `just icon`; needs Pillow and `iconutil`.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

source, target = Path(sys.argv[1]), Path(sys.argv[2])
logo = Image.open(source).convert("RGBA")
# The artwork sits on a white margin: crop to where it is not white, then a
# little further inside its own rounded corners.
white = Image.new("RGBA", logo.size, (255, 255, 255, 255))
box = ImageChops.difference(logo, white).convert("L").point(lambda v: 255 if v > 40 else 0).getbbox()
inset = round((box[2] - box[0]) * 0.02)
logo = logo.crop((box[0] + inset, box[1] + inset, box[2] - inset, box[3] - inset))

size, body = 1024, 824
logo = logo.resize((body, body), Image.LANCZOS)
mask = Image.new("L", (body * 4, body * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, body * 4 - 1, body * 4 - 1), radius=round(body * 4 * 0.225), fill=255)
logo.putalpha(mask.resize((body, body), Image.LANCZOS))
canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
canvas.paste(logo, ((size - body) // 2, (size - body) // 2), logo)

with tempfile.TemporaryDirectory() as work:
    iconset = Path(work) / "Daftar.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            canvas.resize((points * scale,) * 2, Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(target)], check=True)
    canvas.save(target.with_suffix(".png"))
