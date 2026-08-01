#!/usr/bin/env python3
"""Compose the tvOS brand asset catalog from the source artwork in assets/brand/src.

Outputs App/Resources/Assets.xcassets with the full tvOS brandassets structure:
layered App Icon (400x240) + App Icon - App Store (1280x768), Top Shelf Image
(1920x720) and Top Shelf Image Wide (2320x720), each at 1x and 2x where tvOS
asks for it.

Run:  python3 assets/brand/build_assets.py
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "brand" / "src"
OUT = ROOT / "assets" / "brand" / "out"
CATALOG = ROOT / "App" / "Resources" / "Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"

AMBER = (255, 176, 46)
INFO = {"author": "xcode", "version": 1}

# (path, face index) — the index picks an upright weight out of each .ttc,
# never one of the italic faces that sit next to it in the collection.
FONT_CANDIDATES = {
    "heavy": [
        ("/System/Library/Fonts/Avenir Next.ttc", 8),          # Heavy
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1),        # Bold
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0),
    ],
    "bold": [
        ("/System/Library/Fonts/Avenir Next.ttc", 2),          # Demi Bold
        ("/System/Library/Fonts/HelveticaNeue.ttc", 10),       # Medium
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0),
    ],
}


def load_font(size: int, weight: str = "heavy") -> ImageFont.FreeTypeFont:
    for path, index in FONT_CANDIDATES[weight]:
        if not Path(path).exists():
            continue
        try:
            return ImageFont.truetype(path, size, index=index)
        except (OSError, ValueError):
            continue
    return ImageFont.load_default()


def draw_tracked(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str,
                 font: ImageFont.FreeTypeFont, fill, tracking: int) -> None:
    """PIL has no letter-spacing, so lay the glyphs out one at a time."""
    x, y = xy
    for char in text:
        draw.text((x, y), char, font=font, fill=fill)
        x += draw.textlength(char, font=font) + tracking


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def trim_border(img: Image.Image, frac: float = 0.022) -> Image.Image:
    """Drop the cream ink border the source illustrations carry."""
    w, h = img.size
    dx, dy = int(w * frac), int(h * frac)
    return img.crop((dx, dy, w - dx, h - dy))


def cover(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Scale-and-centre-crop img so it fills size exactly."""
    tw, th = size
    sw, sh = img.size
    scale = max(tw / sw, th / sh)
    nw, nh = max(tw, int(round(sw * scale))), max(th, int(round(sh * scale)))
    resized = img.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - tw) // 2, (nh - th) // 2
    return resized.crop((left, top, left + tw, top + th))


def key_out_black(img: Image.Image, lo: int = 26, hi: int = 190) -> Image.Image:
    """Turn a bright mark on a black field into an RGBA cutout.

    Alpha ramps from the `lo` luminance floor to full opacity at `hi`, so the
    mark's outer glow fades out instead of ending on a hard edge.
    """
    rgb = np.asarray(img.convert("RGB"), dtype=np.float32)
    value = rgb.max(axis=2)
    alpha = np.clip((value - lo) / float(hi - lo), 0.0, 1.0)

    # Un-premultiply against black so the glow keeps its colour instead of
    # turning muddy where alpha is low.
    safe = np.clip(alpha, 1e-3, 1.0)[..., None]
    colour = np.clip(rgb / safe, 0, 255)

    out = np.dstack([colour, alpha * 255.0]).astype(np.uint8)
    return Image.fromarray(out, mode="RGBA")


def autocrop_alpha(img: Image.Image, threshold: int = 8) -> Image.Image:
    alpha = np.asarray(img.split()[-1])
    ys, xs = np.where(alpha > threshold)
    if len(xs) == 0:
        return img
    return img.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))


def fit_height(img: Image.Image, height: int) -> Image.Image:
    w, h = img.size
    return img.resize((max(1, round(w * height / h)), height), Image.LANCZOS)


def radial_glow(size: tuple[int, int], radius_frac: float = 0.42) -> Image.Image:
    """Soft amber bloom used as the icon's middle parallax layer."""
    w, h = size
    yy, xx = np.mgrid[0:h, 0:w]
    cx, cy = w / 2.0, h / 2.0
    r = np.sqrt(((xx - cx) / (w * radius_frac)) ** 2 + ((yy - cy) / (h * radius_frac)) ** 2)
    falloff = np.clip(1.0 - r, 0.0, 1.0) ** 2.2

    layer = np.zeros((h, w, 4), dtype=np.float32)
    for i, channel in enumerate(AMBER):
        layer[..., i] = channel
    layer[..., 3] = falloff * 165.0
    return Image.fromarray(layer.astype(np.uint8), mode="RGBA")


def linear_scrim(size: tuple[int, int], to_frac: float = 0.62, strength: int = 225) -> Image.Image:
    """Left-to-right darkening so overlaid text keeps its contrast."""
    w, h = size
    ramp = np.clip(1.0 - (np.arange(w, dtype=np.float32) / (w * to_frac)), 0.0, 1.0) ** 1.5
    alpha = np.tile(ramp, (h, 1)) * strength
    layer = np.zeros((h, w, 4), dtype=np.float32)
    layer[..., 0] = 6
    layer[..., 1] = 12
    layer[..., 2] = 24
    layer[..., 3] = alpha
    return Image.fromarray(layer.astype(np.uint8), mode="RGBA")


# --------------------------------------------------------------------------
# Source artwork
# --------------------------------------------------------------------------

icon_bg_src = trim_border(Image.open(SRC / "icon-bg.png").convert("RGB"))
topshelf_src = trim_border(Image.open(SRC / "topshelf-art.png").convert("RGB"))
mark_src = autocrop_alpha(key_out_black(Image.open(SRC / "icon-mark.png")))

OUT.mkdir(parents=True, exist_ok=True)
mark_src.save(OUT / "mark-alpha.png")


# --------------------------------------------------------------------------
# Layered app icons
# --------------------------------------------------------------------------

def build_icon_layers(size: tuple[int, int]) -> dict[str, Image.Image]:
    w, h = size
    back = cover(icon_bg_src, size).convert("RGBA")
    middle = radial_glow(size)

    front = Image.new("RGBA", size, (0, 0, 0, 0))
    mark = fit_height(mark_src, int(h * 0.56))
    front.paste(mark, ((w - mark.width) // 2, (h - mark.height) // 2), mark)
    return {"Back": back, "Middle": middle, "Front": front}


def write_imagestack(stack_dir: Path, variants: list[tuple[str, tuple[int, int]]]) -> None:
    """variants: [(scale, pixel_size)] e.g. [("1x", (400, 240)), ("2x", (800, 480))]"""
    if stack_dir.exists():
        shutil.rmtree(stack_dir)

    layer_names = ["Front", "Middle", "Back"]
    write_json(stack_dir / "Contents.json", {
        "info": INFO,
        "layers": [{"filename": f"{name}.imagestacklayer"} for name in layer_names],
    })

    rendered = {scale: build_icon_layers(px) for scale, px in variants}

    for name in layer_names:
        layer_dir = stack_dir / f"{name}.imagestacklayer"
        write_json(layer_dir / "Contents.json", {"info": INFO})

        images = []
        content = layer_dir / "Content.imageset"
        content.mkdir(parents=True, exist_ok=True)
        for scale, _px in variants:
            filename = f"{name.lower()}{'' if scale == '1x' else '@' + scale}.png"
            rendered[scale][name].save(content / filename)
            images.append({"filename": filename, "idiom": "tv", "scale": scale})
        write_json(content / "Contents.json", {"images": images, "info": INFO})


write_imagestack(BRAND / "App Icon.imagestack",
                 [("1x", (400, 240)), ("2x", (800, 480))])
write_imagestack(BRAND / "App Icon - App Store.imagestack",
                 [("1x", (1280, 768))])


# --------------------------------------------------------------------------
# Top shelf images
# --------------------------------------------------------------------------

def build_topshelf(size: tuple[int, int]) -> Image.Image:
    w, h = size
    canvas = cover(topshelf_src, size).convert("RGBA")
    canvas.alpha_composite(linear_scrim(size))

    mark = fit_height(mark_src, int(h * 0.30))
    pad = int(w * 0.055)
    mark_y = int(h * 0.30)
    canvas.alpha_composite(mark, (pad, mark_y))

    draw = ImageDraw.Draw(canvas)
    title = load_font(int(h * 0.185), "heavy")
    sub = load_font(int(h * 0.058), "bold")
    text_y = mark_y + mark.height + int(h * 0.045)
    draw.text((pad, text_y), "JRKAN", font=title, fill=(255, 255, 255, 255))

    tb = draw.textbbox((pad, text_y), "JRKAN", font=title)
    draw_tracked(draw, (pad, tb[3] + int(h * 0.020)), "LIVE SPORTS ON APPLE TV",
                 sub, (255, 190, 92, 235), tracking=int(h * 0.010))
    return canvas.convert("RGB")


def write_imageset(imageset_dir: Path, variants: list[tuple[str, tuple[int, int]]],
                   basename: str) -> None:
    if imageset_dir.exists():
        shutil.rmtree(imageset_dir)
    imageset_dir.mkdir(parents=True, exist_ok=True)

    images = []
    for scale, px in variants:
        filename = f"{basename}{'' if scale == '1x' else '@' + scale}.png"
        build_topshelf(px).save(imageset_dir / filename)
        images.append({"filename": filename, "idiom": "tv", "scale": scale})
    write_json(imageset_dir / "Contents.json", {"images": images, "info": INFO})


write_imageset(BRAND / "Top Shelf Image.imageset",
               [("1x", (1920, 720)), ("2x", (3840, 1440))], "topshelf")
write_imageset(BRAND / "Top Shelf Image Wide.imageset",
               [("1x", (2320, 720)), ("2x", (4640, 1440))], "topshelf-wide")


# --------------------------------------------------------------------------
# Catalog manifests
# --------------------------------------------------------------------------

write_json(CATALOG / "Contents.json", {"info": INFO})
write_json(BRAND / "Contents.json", {
    "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
         "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv",
         "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
         "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv",
         "role": "top-shelf-image", "size": "1920x720"},
    ],
    "info": INFO,
})


# --------------------------------------------------------------------------
# Marketing renders (not shipped in the bundle)
# --------------------------------------------------------------------------

def flatten_icon(size: tuple[int, int]) -> Image.Image:
    layers = build_icon_layers(size)
    out = layers["Back"]
    out.alpha_composite(layers["Middle"])
    out.alpha_composite(layers["Front"])
    return out.convert("RGB")


flatten_icon((1280, 768)).save(OUT / "app-store-icon-1280x768.png")
flatten_icon((1024, 1024)).save(OUT / "marketing-icon-1024.png")
build_topshelf((2320, 720)).save(OUT / "topshelf-wide-2320x720.png")

print(f"catalog  -> {CATALOG.relative_to(ROOT)}")
print(f"previews -> {OUT.relative_to(ROOT)}")
