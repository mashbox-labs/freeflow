"""Mac app icon from the iPhone icon: the same 1024 artwork inside the macOS icon shape (an 824 pt rounded square
centred on a 1024 canvas, radius 185, soft shadow), at every size the asset catalog asks for."""
import json, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

src, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
art = Image.open(src).convert("RGBA").resize((824, 824), Image.LANCZOS)
S = 4  # supersample the mask for smooth corners
mask = Image.new("L", (824 * S, 824 * S), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 824 * S - 1, 824 * S - 1), radius=185 * S, fill=255)
mask = mask.resize((824, 824), Image.LANCZOS)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
sm = Image.new("L", (1024, 1024), 0)
sm.paste(mask, (100, 112))
shadow.putalpha(sm.point(lambda a: int(a * 0.28)))
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas.alpha_composite(shadow)
art.putalpha(mask)
canvas.alpha_composite(art, (100, 100))
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        canvas.resize((px, px), Image.LANCZOS).save(out / name, optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
(out / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=1) + "\n")
(out.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=1) + "\n")
print("ok", len(images))
