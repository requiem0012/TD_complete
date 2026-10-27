"""Prepare local HD sample media; no physical disk access."""
from pathlib import Path
import json, struct
from PIL import Image
from hd_media import *
import bmp2raw
import mp4_to_tf_video as video

ROOT=Path(__file__).resolve().parent
def main():
    merged=bytearray()
    info=[]
    for i in range(1,5):
        source=ROOT/f"image{i}.img"
        raw=source.read_bytes()
        if len(raw)!=60000:raise ValueError("Expected copied legacy RGB565 sample")
        values=struct.unpack("<30000H",raw)
        pixels=[]
        for v in values:
            r,g,b=v>>11,(v>>5)&63,v&31
            pixels.append(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)))
        image=Image.new("RGB",(200,150));image.putdata(pixels)
        fitted=bmp2raw.resize_image(image,"contain","black")
        packed=pack_photo(fitted);item=inspect_photo(packed)
        path=ROOT/f"image{i}_hd.img"
        path.write_bytes(packed)
        merged.extend(packed.ljust(65536,b"\0"))
        item.update(output=path.name,source_resolution="200x150 (compatibility sample, not newly recovered detail)",lba=(i-1)*128)
        info.append(item)
    (ROOT/"TF_HD_4images.img").write_bytes(merged)
    (ROOT/"TF_HD_4images.json").write_text(json.dumps(info,indent=2)+"\n")
    for name in ("red","green","blue"):
        p=pack_photo(Image.new("RGB",(WIDTH,HEIGHT),"lime" if name=="green" else name)).ljust(65536,b"\0")
        (ROOT/"tests"/f"hd_{name}.hex").write_text("\n".join(f"{b:02x}" for b in p)+"\n")
    clip=ROOT/"demo0_hd.bin"
    video.inspect(clip)
    with clip.open("rb") as f:f.seek(512);bc=f.read(PAYLOAD_BYTES)
    decode_preview(bc).save(ROOT/"demo0_hd_preview.png")
    print("Created TF_HD_4images.img, four HXIMAGE2 files, preview and solid-color simulation fixtures.")
    print("These old 200x150 photos are upscaled only. For actual extra detail, convert original high-resolution photos.")
if __name__=="__main__":main()
