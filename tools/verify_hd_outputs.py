"""Verify the complete generated HD samples, including every PCM byte."""
import argparse, hashlib, json, struct, subprocess
from io import BytesIO
from pathlib import Path
from PIL import Image
import mp4_to_tf_video as media
from hd_media import *
ROOT=Path(__file__).resolve().parent
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suffix',choices=('_hd','_hq'),default='_hq')
    options=parser.parse_args()
    for n in range(2):
        path=ROOT/f"demo{n}{options.suffix}.bin"
        info=media.inspect(path)
        digest=hashlib.sha256()
        dds=BytesIO();Image.new("RGB",(WIDTH,HEIGHT)).save(dds,format="DDS",pixel_format="DXT1")
        dh=dds.getvalue()[:128]
        with path.open("rb") as file:
            file.seek(512)
            for frame in range(info["frames"]):
                record=file.read(media.RECORD_BYTES)
                if len(record)!=media.RECORD_BYTES:raise AssertionError("Truncated record")
                if any(record[PAYLOAD_BYTES:65536]) or any(record[65536+12000:]):
                    raise AssertionError("Nonzero record padding")
                digest.update(record[65536:65536+12000])
                Image.open(BytesIO(dh+record[:PAYLOAD_BYTES])).load()
        source=ROOT/f"demo{n}.mp4"
        args=[media.executable("ffmpeg"),"-v","error","-nostdin","-i",str(source),
              "-map","0:a:0","-vn","-ac","1","-ar","48000","-af","apad",
              "-t",str(info["frames"]/8),"-c:a","pcm_s16le","-f","s16le","pipe:1"]
        pcm=subprocess.run(args,capture_output=True,check=True).stdout
        pcm=pcm.ljust(info["frames"]*12000,b"\0")
        assert digest.hexdigest()==hashlib.sha256(pcm).hexdigest()
        print(json.dumps(dict(file=path.name,frames=info["frames"],
              all_bc1_frames_decodable=True,all_padding_zero=True,
              pcm_sha256=digest.hexdigest(),pcm_matches_ffmpeg=True)))
    for n in range(1,5):inspect_photo((ROOT/f"image{n}_hd.img").read_bytes())
    assert (ROOT/"TF_HD_4images.img").stat().st_size==262144
    print("PASS all generated HD media: every frame, all PCM bytes, four photo CRCs")
if __name__=="__main__":main()
