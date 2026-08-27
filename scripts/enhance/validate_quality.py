"""Tile each sample through the Core ML model (256->1024), stitch a 4x image,
then Lanczos-downscale to 2x. Writes before/after into out/ for eyeballing.
This mirrors what Plan B's ImageEnhancer will do in Swift.
"""
import os, glob
import coremltools as ct
from PIL import Image

TILE, UP = 256, 4
m = ct.models.MLModel("scripts/enhance/out/RealESRGeneralX4V3.mlpackage")
os.makedirs("scripts/enhance/out", exist_ok=True)


def enhance(img):
    w, h = img.size
    big = Image.new("RGB", (w * UP, h * UP))
    for ty in range(0, h, TILE):
        for tx in range(0, w, TILE):
            tile = Image.new("RGB", (TILE, TILE))
            crop = img.crop((tx, ty, min(tx + TILE, w), min(ty + TILE, h)))
            tile.paste(crop, (0, 0))                       # edge tiles zero-padded
            out = m.predict({"image": tile})["output"]
            valid = (min(TILE, w - tx) * UP, min(TILE, h - ty) * UP)
            big.paste(out.crop((0, 0, *valid)), (tx * UP, ty * UP))
    return big.resize((w * 2, h * 2), Image.LANCZOS)        # downscale 4x -> 2x


for f in sorted(glob.glob("poc/resolution-modify/*.png")):
    name = os.path.splitext(os.path.basename(f))[0]
    img = Image.open(f).convert("RGB")
    enhance(img).save(f"scripts/enhance/out/{name}_enhanced2x.png")
    print("enhanced", name, img.size, "-> 2x")
