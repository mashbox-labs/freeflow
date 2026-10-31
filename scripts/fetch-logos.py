#!/usr/bin/env python3
"""Fetches model-maker logos from LobeHub Icons (@lobehub/icons-static-png, MIT, Copyright (c) 2023 LobeHub)
at a pinned version into App/Assets.xcassets/Logos as light/dark image sets. Build-time only: the app never
downloads logos. The logos are trademarks of their owners and are shown only on the in-app model and credits
screens to say who made each model; never in the app icon, store screenshots or store text."""
import io
import json
import sys
import urllib.request
from pathlib import Path

from PIL import Image

VERSION = "1.97.1"  # pinned 2026-10-29; package.json at this version: "license": "MIT"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "App/Assets.xcassets/Logos"
# asset name -> LobeHub icon name. Not from here: logo-moondream, logo-fermion and logo-conway are the makers' Hugging Face
# profile pictures as served 2026-10-31 (WebP, decoded to PNG with sips, pixels unchanged).
LOGOS = {
    "logo-nvidia": "nvidia-color",          # Parakeet TDT 0.6B v3
    "logo-huggingface": "huggingface-color",  # where the model files are downloaded from
    "logo-github": "github",                # where WhisperKit and FluidAudio are developed
}


def fetch(theme, name):
    url = f"https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@{VERSION}/{theme}/{name}.png"
    with urllib.request.urlopen(url, timeout=30) as response:
        return Image.open(io.BytesIO(response.read())).convert("RGBA")


OUT.mkdir(parents=True, exist_ok=True)
(OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, indent=2) + "\n")
failed = []
for asset, name in LOGOS.items():
    folder = OUT / f"{asset}.imageset"
    folder.mkdir(exist_ok=True)
    images = []
    for theme, appearance in (("light", None), ("dark", "dark")):
        try:
            image = fetch(theme, name)
        except Exception as error:  # noqa: BLE001
            failed.append(f"{name} ({theme}): {error}")
            continue
        image.thumbnail((128, 128))
        filename = f"{asset}-{theme}.png"
        image.save(folder / filename, optimize=True)
        entry = {"filename": filename, "idiom": "universal"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    (folder / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print(f"{len(LOGOS)} logos into {OUT.relative_to(ROOT)}; {len(failed)} missing")
for line in failed:
    print("missing:", line)
sys.exit(1 if failed else 0)
