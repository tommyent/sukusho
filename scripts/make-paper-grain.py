#!/usr/bin/env python3
"""Bakes Screendrop/PaperGrain.png, Chip's paper grain, from ambientCG's Paper006 (CC0 1.0, https://ambientcg.com/a/Paper006).

Usage: scripts/make-paper-grain.py <Paper006_2K-JPG_Color.jpg> <out.png> [scale]. Needs ImageMagick (magick).

The scan is used as grain only: its luminance (no colour), less a heavy blur of itself (no large-scale shading),
scaled so its grain is the size of the approved mockup's on a 220 pt card at 2x, made seamless by fading towards a
half-offset copy at the edges.
The grain is centred on zero and scaled to the spread the owner approved in the mockups. A multiply of its dark
marks and a screen of its light marks would need two blended layers per card; over any colour, a multiply by t equals
black at alpha 1 - t and a screen by u equals white at alpha u, so the tile is just black and white marks at those
alphas, drawn normally over the paper, the same tile in light and dark. The theme's strength (Chip: 0.35, subtle) is
applied in the app as the tile's opacity, which is exact because each pixel holds only one kind of mark, and keeps
the alpha's 8-bit steps as fine as the mockup's.
"""
import math
import subprocess
import sys
import tempfile
from pathlib import Path

SPREAD = 0.0907        # the grain's standard deviation in the approved mockup (round 2, subtle)
DARK, LIGHT = 0.42, 0.72  # how far the multiply darkens and the screen lifts at full grain
SIZE = 512

source, out = Path(sys.argv[1]), Path(sys.argv[2])
SCALE = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5   # output pixels per scan pixel
crop = round(SIZE / SCALE)
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    run = lambda *a: subprocess.run(["magick", *map(str, a)], check=True)
    run(source, "-gravity", "Center", "-crop", f"{crop}x{crop}+0+0", "+repage", "-colorspace", "Gray",
        "(", "+clone", "-blur", "0x24", ")", "-compose", "Mathematics", "-define", "compose:args=0,-1,1,0.5",
        "-composite", "-resize", f"{SIZE}x{SIZE}!", tmp / "flat.png")
    run(tmp / "flat.png", "-roll", f"+{SIZE // 2}+{SIZE // 2}", tmp / "rolled.png")
    run("-size", f"{SIZE}x{SIZE}", "xc:black", "-fx", "min(min(i,w-1-i),min(j,h-1-j))/(w/2)",
        "-evaluate", "Pow", "0.7", tmp / "mask.png")
    # 8-bit, as the approved mockup's tile was: its few grey levels are part of the grain's crispness.
    run(tmp / "rolled.png", tmp / "flat.png", tmp / "mask.png", "-compose", "Over", "-composite",
        "-depth", "8", f"gray:{tmp / 'tile.gray'}")

    values = [byte / 255 for byte in (tmp / "tile.gray").read_bytes()]
    assert len(values) == SIZE * SIZE
    mean = sum(values) / len(values)
    sd = math.sqrt(sum((v - mean) ** 2 for v in values) / len(values))

    rgba = bytearray()
    for v in values:
        g = max(-1.0, min(1.0, (v - mean) / sd * SPREAD))
        alpha = DARK * -g if g < 0 else LIGHT * g
        shade = 0 if g < 0 else 255
        rgba += bytes((shade, shade, shade, round(alpha * 255)))
    (tmp / "tile.rgba").write_bytes(bytes(rgba))
    run("-size", f"{SIZE}x{SIZE}", "-depth", "8", f"rgba:{tmp / 'tile.rgba'}", "-define", "png:color-type=4",
        "-strip", out)
print(f"{out}: {SIZE}x{SIZE}, scale {SCALE}, grain spread {SPREAD}, from {source.name}")
