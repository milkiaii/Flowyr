#!/usr/bin/env python3
"""Encode the root logo images as 1024px opaque iOS icons using ImageMagick.

logo.png      -> AppIcon.png       (default appearance)
logo-dark.png -> AppIcon-Dark.png  (iOS dark appearance)
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
ICONSET = ROOT / "ios/Vita3K/App/Assets.xcassets/AppIcon.appiconset"
ICONS = {"logo.png": "AppIcon.png", "logo-dark.png": "AppIcon-Dark.png"}


def render(source: Path, output: Path):
    dimensions = subprocess.check_output(
        ["magick", "identify", "-format", "%w %h", str(source)], text=True,
    ).split()
    if len(dimensions) != 2 or dimensions[0] != dimensions[1]:
        raise SystemExit(f"{source.name} must be square to preserve its framing in the iOS icon.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Preserve the supplied artwork and framing. iOS supplies the corner mask.
    subprocess.run(
        ["magick", str(source), "-resize", "1024x1024", "-colorspace", "sRGB",
         "-background", "#2a1200", "-alpha", "remove", "-alpha", "off",
         "-strip", "-depth", "8", f"PNG24:{output}"],
        check=True,
    )
    print(output)


def main():
    for src, dst in ICONS.items():
        render(ROOT / src, ICONSET / dst)


if __name__ == "__main__":
    main()
