#!/usr/bin/env python3
"""Encode the root logo.png as a 1024px opaque iOS icon using ImageMagick."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def main():
    source = ROOT / "logo.png"
    output = ROOT / "ios/Vita3K/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    dimensions = subprocess.check_output(
        ["magick", "identify", "-format", "%w %h", str(source)], text=True,
    ).split()
    if len(dimensions) != 2 or dimensions[0] != dimensions[1]:
        raise SystemExit("logo.png must be square to preserve its framing in the iOS icon.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Preserve the supplied artwork and framing. iOS supplies the corner mask.
    subprocess.run(
        ["magick", str(source), "-resize", "1024x1024", "-colorspace", "sRGB",
         "-background", "#2a1200", "-alpha", "remove", "-alpha", "off",
         "-strip", "-depth", "8", f"PNG24:{output}"],
        check=True,
    )
    print(output)


if __name__ == "__main__":
    main()
