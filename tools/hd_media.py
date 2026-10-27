"""HXIMAGE3/HXVIDEO3 shared BC1 format. Never writes physical disks."""
from io import BytesIO
import struct
import zlib
from PIL import Image

WIDTH, HEIGHT = 640, 480
PAYLOAD_BYTES = WIDTH * HEIGHT // 2
PHOTO_MAGIC = b"HXIMAGE3"

def encode_bc1_fast(image):
    image = image.convert("RGB")
    if image.size != (WIDTH, HEIGHT):
        raise ValueError(f"Expected {WIDTH}x{HEIGHT}")
    stream = BytesIO()
    image.save(stream, format="DDS", pixel_format="DXT1")
    dds = stream.getvalue()
    if dds[:4] != b"DDS " or dds[84:88] != b"DXT1" or len(dds) != 128 + PAYLOAD_BYTES:
        raise ValueError("Pillow did not produce the required DXT1 layout (use Pillow >=12)")
    return dds[128:]

def encode_bc1(image, quality="hq"):
    baseline = encode_bc1_fast(image)
    if quality == "fast":
        return baseline
    if quality != "hq":
        raise ValueError("Quality must be hq or fast")
    from bc1_hq import refine_bc1
    return refine_bc1(image, baseline)

def pack_photo(image, quality="hq"):
    payload = encode_bc1(image, quality=quality)
    prefix = struct.pack("<8s5I", PHOTO_MAGIC, 3, WIDTH, HEIGHT, PAYLOAD_BYTES, zlib.crc32(payload))
    header = prefix + struct.pack("<I", zlib.crc32(prefix))
    return header.ljust(512, b"\0") + payload

def inspect_photo(data):
    if len(data) != 512 + PAYLOAD_BYTES:
        raise ValueError("Invalid HXIMAGE3 length")
    magic, version, w, h, count, crc, hc = struct.unpack("<8s6I", data[:32])
    if (magic, version, w, h, count) != (PHOTO_MAGIC, 3, WIDTH, HEIGHT, PAYLOAD_BYTES):
        raise ValueError("Unsupported photo header")
    if hc != zlib.crc32(data[:28]) or crc != zlib.crc32(data[512:]):
        raise ValueError("Photo CRC32 mismatch")
    return {"width":w, "height":h, "payload_bytes":count, "crc32":f"{crc:08X}"}

def decode_preview(payload):
    # Pillow constructs a standards-compliant DDS header for the same geometry.
    temp = BytesIO()
    Image.new("RGB", (WIDTH, HEIGHT)).save(temp, format="DDS", pixel_format="DXT1")
    return Image.open(BytesIO(temp.getvalue()[:128] + payload)).convert("RGB")
