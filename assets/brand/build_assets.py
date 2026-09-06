#!/usr/bin/env python3
"""Package leeguoo's generated artwork into the iOS / tvOS asset catalogs.

Source artwork is generated with imagegen in assets/brand/src. This script only
sizes the artwork and assembles Apple's catalog/layer structure. It preserves
native transparency; no black color-keying, recoloring, glow or added typography.
Run: python3 assets/brand/build_assets.py
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets/brand/src"
OUT = ROOT / "assets/brand/out"
CATALOG = ROOT / "App/Resources/Assets.xcassets"
IOS_CATALOG = ROOT / "App/Resources/iOSAssets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"
INFO = {"author": "xcode", "version": 1}
ILLUSTRATIONS = [
    ("empty-nomatch", "EmptyNoMatch"),
    ("empty-offline", "EmptyOffline"),
    ("empty-nochannel", "EmptyNoChannel"),
    ("empty-search", "EmptySearch"),
]


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(image, size, method=Image.Resampling.LANCZOS)


def fit_height(image: Image.Image, height: int) -> Image.Image:
    return image.resize((round(image.width * height / image.height), height), Image.Resampling.LANCZOS)


def scaled_variants(image: Image.Image, height: int, scales: tuple[int, ...]) -> list[tuple[str, Image.Image]]:
    width = round(image.width * height / image.height)
    return [(f"{scale}x", image.resize((width * scale, height * scale), Image.Resampling.LANCZOS)) for scale in scales]


def transparent_source(name: str) -> Image.Image:
    image = Image.open(SRC / f"{name}.png")
    if image.mode != "RGBA" or image.getchannel("A").getextrema()[0] != 0:
        raise ValueError(f"{name} must have generated transparent alpha, not a keyed background")
    bounds = image.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError(f"{name} is empty")
    return image.crop(bounds)


def imageset(path: Path, variants: list[tuple[str, Image.Image]], name: str, idiom: str) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True)
    entries = []
    for scale, image in variants:
        filename = f"{name}{'' if scale == '1x' else '@' + scale}.png"
        image.save(path / filename)
        entries.append({"filename": filename, "idiom": idiom, "scale": scale})
    write_json(path / "Contents.json", {"images": entries, "info": INFO})


# Read and validate all sources before replacing any generated catalog output.
mark = transparent_source("icon-mark")
illustrations = {name: transparent_source(name) for name, _ in ILLUSTRATIONS}
background = Image.open(SRC / "icon-bg.png").convert("RGB")
banner = Image.open(SRC / "topshelf-art.png").convert("RGB")
launch = Image.open(SRC / "launch-art.png").convert("RGB")
icon = Image.open(SRC / "ios-icon.png").convert("RGB")
OUT.mkdir(parents=True, exist_ok=True)


def icon_layers(size: tuple[int, int]) -> dict[str, Image.Image]:
    back = cover(background, size).convert("RGBA")
    front = Image.new("RGBA", size)
    emblem = fit_height(mark, round(size[1] * 0.68))
    front.alpha_composite(emblem, ((size[0] - emblem.width) // 2, (size[1] - emblem.height) // 2))
    # Keep the existing three-layer catalog layout. The quiet middle layer
    # avoids reintroducing the old glow; the foreground mark supplies parallax.
    return {"Front": front, "Middle": Image.new("RGBA", size), "Back": back}


def imagestack(path: Path, sizes: list[tuple[str, tuple[int, int]]]) -> None:
    if path.exists():
        shutil.rmtree(path)
    layers = ["Front", "Middle", "Back"]
    write_json(path / "Contents.json", {"info": INFO,
        "layers": [{"filename": f"{name}.imagestacklayer"} for name in layers]})
    rendered = {scale: icon_layers(size) for scale, size in sizes}
    for layer in layers:
        target = path / f"{layer}.imagestacklayer"
        write_json(target / "Contents.json", {"info": INFO})
        imageset(target / "Content.imageset", [(scale, rendered[scale][layer]) for scale, _ in sizes], layer.lower(), "tv")


imagestack(BRAND / "App Icon.imagestack", [("1x", (400, 240)), ("2x", (800, 480))])
imagestack(BRAND / "App Icon - App Store.imagestack", [("1x", (1280, 768))])
for name, width, basename in [("Top Shelf Image", 1920, "topshelf"), ("Top Shelf Image Wide", 2320, "topshelf-wide")]:
    imageset(BRAND / f"{name}.imageset", [(f"{scale}x", cover(banner, (width * scale, 720 * scale))) for scale in (1, 2)], basename, "tv")

write_json(CATALOG / "Contents.json", {"info": INFO})
write_json(BRAND / "Contents.json", {"assets": [
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
], "info": INFO})

imageset(CATALOG / "LaunchArt.imageset", [("1x", cover(launch, (1920, 1080))), ("2x", cover(launch, (3840, 2160)))], "launch", "tv")
imageset(CATALOG / "BrandMark.imageset", scaled_variants(mark, 240, (1, 2)), "mark", "tv")
for name, asset in ILLUSTRATIONS:
    imageset(CATALOG / f"{asset}.imageset", scaled_variants(illustrations[name], 300, (1, 2)), asset.lower(), "tv")

# iOS / iPadOS / Mac Catalyst share the opaque square icon and universal artwork.
write_json(IOS_CATALOG / "Contents.json", {"info": INFO})
icon_dir = IOS_CATALOG / "AppIcon.appiconset"
icon_dir.mkdir(parents=True, exist_ok=True)
cover(icon, (1024, 1024)).save(icon_dir / "icon-1024.png")
write_json(icon_dir / "Contents.json", {"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": INFO})
write_json(IOS_CATALOG / "LaunchBackground.colorset/Contents.json", {"colors": [{"idiom": "universal", "color": {
    "color-space": "srgb", "components": {"red": "0.039", "green": "0.047", "blue": "0.075", "alpha": "1.000"},
}}], "info": INFO})
imageset(IOS_CATALOG / "BrandMark.imageset", scaled_variants(mark, 120, (1, 2, 3)), "mark", "universal")
imageset(IOS_CATALOG / "LaunchArt.imageset", [("1x", cover(launch, (1080, 720))), ("2x", cover(launch, (2160, 1440)))], "launch", "universal")
for name, asset in ILLUSTRATIONS:
    imageset(IOS_CATALOG / f"{asset}.imageset", scaled_variants(illustrations[name], 160, (1, 2, 3)), asset.lower(), "universal")

# Review renders of exactly the shipped artwork.
for size, name in [((1280, 768), "app-store-icon-1280x768"), ((1024, 1024), "marketing-icon-1024")]:
    layers = icon_layers(size)
    result = layers["Back"]
    result.alpha_composite(layers["Front"])
    result.convert("RGB").save(OUT / f"{name}.png")
mark.save(OUT / "mark-alpha.png")
cover(icon, (1024, 1024)).save(OUT / "ios-icon-1024.png")
cover(banner, (2320, 720)).save(OUT / "topshelf-wide-2320x720.png")
cover(launch, (1920, 1080)).save(OUT / "launch-1920x1080.png")
print("Packaged tvOS, iOS and Mac Catalyst brand assets.")
