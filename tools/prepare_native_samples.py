"""Create new native assets only. No physical device access or old-file overwrite."""
from pathlib import Path
from PIL import Image
import json,zlib
from bmp2raw import resize_image
from hd_media import pack_photo,inspect_photo,decode_preview

ROOT=Path(__file__).resolve().parent
SLOT=262144
def main():
    combined=ROOT/'TF_NATIVE_4images.img'
    if combined.exists():raise ValueError('Native combined image already exists')
    records=[]
    with combined.open('xb') as target:
        for n in range(1,5):
            path=ROOT/f'image{n}_native.img'
            if path.exists():raise ValueError(f'Already exists: {path}')
            with Image.open(ROOT/f'image{n}.bmp') as source:
                image=resize_image(source,'contain','black')
            data=pack_photo(image,quality='hq')
            info=inspect_photo(data)
            path.write_bytes(data)
            target.write(data.ljust(SLOT,b'\0'))
            records.append(dict(file=path.name,lba=(n-1)*512,**info))
            if n==1:decode_preview(data[512:]).save(ROOT/'native_photo_preview.png')
            print(f'Created {path.name}: {len(data)} bytes',flush=True)
    (ROOT/'TF_NATIVE_4images.json').write_text(json.dumps(records,indent=2)+'\n')
    print(f'Created {combined.name}: {combined.stat().st_size} bytes',flush=True)
if __name__=='__main__':main()
