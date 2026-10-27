"""Pack exactly four source images for the native SDRAM player; no disk IO.

Only ordinary output files are created. Existing directories are never replaced.
"""
from pathlib import Path
import argparse
import hashlib
import json
from PIL import Image, ImageOps
from bmp2raw import resize_image
from hd_media import WIDTH, HEIGHT, pack_photo, inspect_photo, decode_preview

SLOT_BYTES = 262144

def sha256(data):
    return hashlib.sha256(data).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('images', nargs=4, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output.exists():
        raise ValueError(f'Refusing to overwrite existing directory: {output}')
    prepared = []
    for path in args.images:
        path = path.resolve(strict=True)
        source_bytes = path.read_bytes()
        with Image.open(path) as source:
            original_size = source.size
            oriented = ImageOps.exif_transpose(source)
            content_size = ImageOps.contain(oriented, (WIDTH, HEIGHT),
                                           Image.Resampling.LANCZOS).size
            image = resize_image(source, 'contain', 'black')
        data = pack_photo(image, quality='hq')
        metadata = inspect_photo(data)
        prepared.append((path, data, dict(source=str(path),
            source_sha256=sha256(source_bytes), original_size=original_size,
            content_size=content_size, fit='contain', background='black',
            encoder='hq', **metadata)))
    output.mkdir(parents=True, exist_ok=False)
    combined = bytearray()
    preview = Image.new('RGB', (WIDTH*2, HEIGHT*2))
    records = []
    for i, (source, data, metadata) in enumerate(prepared):
        filename = f'image{i+1}_native.img'
        (output/filename).write_bytes(data)
        decoded = decode_preview(data[512:])
        decoded.save(output/f'image{i+1}_preview.png')
        preview.paste(decoded, ((i%2)*WIDTH, (i//2)*HEIGHT))
        slot = data.ljust(SLOT_BYTES, b'\0')
        combined.extend(slot)
        metadata.update(image=i+1, output=filename, bytes=len(data),
                        sha256=sha256(data), lba=i*512, byte_offset=i*SLOT_BYTES)
        records.append(metadata)
        print(f'{source.name} -> {filename}: {metadata["original_size"]} -> '
              f'{WIDTH}x{HEIGHT}, content={metadata["content_size"]}, '
              f'CRC32={metadata["crc32"]}', flush=True)
    assert len(combined) == 1048576
    bundle = output/'TF_NATIVE_4images.img'
    bundle.write_bytes(combined)
    preview.save(output/'preview_4images.png')
    # Reopen the actual delivered files, not just encoder return values.
    readback = bundle.read_bytes()
    for i, item in enumerate(records):
        single = (output/item['output']).read_bytes()
        inspect_photo(single)
        assert sha256(single) == item['sha256']
        segment = readback[i*SLOT_BYTES:(i+1)*SLOT_BYTES]
        assert segment[:len(single)] == single
        assert not any(segment[len(single):])
    manifest = dict(format='HXIMAGE3', canvas=[WIDTH, HEIGHT],
        combined_file=bundle.name, combined_bytes=len(readback),
        combined_sha256=sha256(readback), physical_byte_offset=0,
        slot_bytes=SLOT_BYTES, images=records,
        physical_disk_written=False, bit_rebuild_required=False)
    (output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'PASS: all headers/payload CRC32, slot offsets and zero padding verified. '
          f'Combined {len(readback)} bytes, SHA256={manifest["combined_sha256"]}',flush=True)
    print(f'OUTPUT: {bundle}',flush=True)

if __name__ == '__main__':
    main()
