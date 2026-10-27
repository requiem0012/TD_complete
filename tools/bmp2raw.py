#!/usr/bin/env python3
"""Convert an arbitrary image to a 640x480 BC1 HXIMAGE3 photo.

The output is 154112 bytes (512-byte CRC-protected header + 153600 BC1 bytes).
Use only with TF_complete_SDRAM_Player firmware. Existing RGB565 firmware cannot read it.

Examples:
    python bmp2raw.py photo.jpg image0.img
    python bmp2raw.py portrait.png image1.img --fit contain --background black
    python bmp2raw.py wide.webp image2.img --fit cover
    python bmp2raw.py legacy.bmp image3.img --fit stretch
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from hd_media import WIDTH as FB_W, HEIGHT as FB_H, pack_photo, inspect_photo, decode_preview


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="input image (any Pillow format)")
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        help="output .img/.raw path (default: input name with .img suffix)",
    )
    parser.add_argument(
        "--fit",
        choices=("contain", "cover", "stretch"),
        default="contain",
        help="aspect policy; contain adds bars, cover crops, stretch distorts",
    )
    parser.add_argument(
        "--background",
        default="black",
        help="Pillow color used for contain bars (default: black)",
    )
    parser.add_argument("--quality", choices=("hq", "fast"), default="hq", help="BC1 fitting quality (hq requires NumPy)")
    parser.add_argument("--force", action="store_true", help="replace an existing output")
    parser.add_argument("--preview", type=Path, help="optional decoded BC1 preview PNG")
    return parser.parse_args(argv)


def resize_image(image, fit: str, background: str):
    from PIL import Image, ImageColor, ImageOps

    image = ImageOps.exif_transpose(image)
    if "A" in image.getbands() or "transparency" in image.info:
        rgba = image.convert("RGBA")
        base = Image.new("RGBA", rgba.size, ImageColor.getrgb(background) + (255,))
        image = Image.alpha_composite(base, rgba).convert("RGB")
    else:
        image = image.convert("RGB")
    resampling = getattr(Image, "Resampling", Image).LANCZOS

    if fit == "stretch":
        return image.resize((FB_W, FB_H), resampling)
    if fit == "cover":
        return ImageOps.fit(image, (FB_W, FB_H), method=resampling, centering=(0.5, 0.5))

    resized = ImageOps.contain(image, (FB_W, FB_H), method=resampling)
    canvas = Image.new("RGB", (FB_W, FB_H), ImageColor.getrgb(background))
    left = (FB_W - resized.width) // 2
    top = (FB_H - resized.height) // 2
    canvas.paste(resized, (left, top))
    return canvas



def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    output_path = args.output or args.input.with_suffix(".img")

    try:
        from PIL import Image
    except ImportError:
        print("Pillow is required: python -m pip install Pillow", file=sys.stderr)
        return 3

    try:
        with Image.open(args.input) as source:
            original_size = source.size
            image = resize_image(source, args.fit, args.background)
    except Exception as exc:
        print(f"failed to open/resize {args.input}: {exc}", file=sys.stderr)
        return 3

    if output_path.resolve() == args.input.resolve() or (output_path.exists() and not args.force):
        print("Refusing to overwrite input/existing output (use --force for output)", file=sys.stderr)
        return 2
    try:
        raw = pack_photo(image, quality=args.quality)
    except ImportError:
        print("HQ needs NumPy: python -m pip install -r requirements_hd.txt (or --quality fast)", file=sys.stderr)
        return 3
    inspect_photo(raw)
    output_path.write_bytes(raw)
    if args.preview:
        if args.preview.resolve() in (args.input.resolve(), output_path.resolve()) or args.preview.exists():
            raise ValueError("Preview must be a new, separate file")
        decode_preview(raw[512:]).save(args.preview)
    print(
        f"wrote {output_path}: {original_size[0]}x{original_size[1]} -> "
        f"{FB_W}x{FB_H} BC1 HXIMAGE3, {len(raw)} bytes, fit={args.fit}"
    )
    print("TF slots start at LBA 0, 512, 1024, 1536 (512-byte sectors; zero-pad each slot to 262144 bytes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
