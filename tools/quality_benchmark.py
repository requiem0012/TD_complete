"""Reproducible quality measurements. No physical disk access."""
from io import BytesIO
from pathlib import Path
import json, math, subprocess, time
import numpy as np
from PIL import Image, ImageDraw
from hd_media import WIDTH,HEIGHT,encode_bc1_fast,decode_preview,pack_photo,inspect_photo
from bc1_hq import refine_bc1,decoded_blocks,blocks_from_image
import mp4_to_tf_video as media

ROOT=Path(__file__).resolve().parent
def image_from_blocks(b):
    return Image.fromarray(b.reshape(HEIGHT//4,WIDTH//4,4,4,3).transpose(0,2,1,3,4).reshape(HEIGHT,WIDTH,3).astype(np.uint8))
def extract(source,seconds):
    fit=f"scale=iw*sar:ih,setsar=1,scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2:black"
    result=subprocess.run([media.executable("ffmpeg"),"-v","error","-ss",str(seconds),"-i",str(source),
        "-frames:v","1","-vf",fit,"-pix_fmt","rgb24","-f","rawvideo","pipe:1"],capture_output=True,check=True)
    return Image.frombytes("RGB",(WIDTH,HEIGHT),result.stdout)
def resize(a,bits=None):
    posx=np.arange(640,dtype=np.float64)*13/20
    posy=np.arange(480,dtype=np.float64)*13/20
    if bits is not None:
        posx=np.floor(posx*(1<<bits))/(1<<bits)
        posy=np.floor(posy*(1<<bits))/(1<<bits)
    sx=np.floor(posx).astype(int);sy=np.floor(posy).astype(int)
    nx=np.minimum(sx+1,WIDTH-1);ny=np.minimum(sy+1,HEIGHT-1)
    fx=(posx-sx)[None,:,None];fy=(posy-sy)[:,None,None]
    top=a[sy[:,None],sx[None,:]]*(1-fx)+a[sy[:,None],nx[None,:]]*fx
    bot=a[ny[:,None],sx[None,:]]*(1-fx)+a[ny[:,None],nx[None,:]]*fx
    return np.floor(top*(1-fy)+bot*fy+0.5)
def main():
    cases=[]
    for name,color in [("black","black"),("white","white"),("red","red"),("green","lime"),("blue","blue")]:
        cases.append((name,Image.new("RGB",(WIDTH,HEIGHT),color)))
    yy,xx=np.mgrid[:HEIGHT,:WIDTH]
    grad=np.stack((xx*255//(WIDTH-1),yy*255//(HEIGHT-1),(xx+yy)%256),axis=-1).astype(np.uint8)
    cases.append(("gradient",Image.fromarray(grad)))
    text=Image.new("RGB",(WIDTH,HEIGHT),"black");draw=ImageDraw.Draw(text)
    for y in range(0,HEIGHT,18):
        draw.text((2,y),"FPGA HDMI BC1 416x312 0123456789",fill=(255,(y*7)%256,128))
    cases.append(("fine_text",text))
    cases.append(("noise",Image.fromarray(np.random.default_rng(20261020).integers(0,256,(HEIGHT,WIDTH,3),dtype=np.uint8))))
    for movie in (0,1):
        for t in (0,3,7):
            cases.append((f"demo{movie}_{t}s",extract(ROOT/f"demo{movie}.mp4",t)))
    results=[]
    for name,image in cases:
        baseline=encode_bc1_fast(image);start=time.perf_counter()
        improved,stats=refine_bc1(image,baseline,return_stats=True)
        stats.update(case=name,encode_seconds=time.perf_counter()-start)
        # Both error measurements use the exact FPGA endpoint expansion and palette.
        assert stats["max_block_error_increase"]<=0
        assert len(improved)==64896
        decoded=image_from_blocks(decoded_blocks(improved))
        independent=np.asarray(decode_preview(improved),dtype=np.int32)
        assert np.max(np.abs(np.asarray(decoded,dtype=np.int32)-independent))<=1
        source=np.asarray(image,dtype=np.float64)
        fast=np.asarray(decode_preview(baseline),dtype=np.float64)
        hq=np.asarray(decoded,dtype=np.float64)
        for quality,sse in [("fast",stats["baseline_sse"]),("hq",stats["hq_sse"])]:
            stats[quality+"_psnr_db"]=None if sse==0 else 10*math.log10(255**2/(sse/(WIDTH*HEIGHT*3)))
        ideal=resize(hq);low=resize(hq,4);high=resize(hq,8)
        stats["scaler_4bit_mse_vs_exact"]=float(np.mean((low-ideal)**2))
        stats["scaler_8bit_mse_vs_exact"]=float(np.mean((high-ideal)**2))
        results.append(stats)
        print(json.dumps(stats),flush=True)
        if name=="demo0_3s":
            preview=Image.new("RGB",(WIDTH*3,HEIGHT+24),"#202020");d=ImageDraw.Draw(preview)
            for i,(label,img) in enumerate([("REFERENCE RESIZED",image),("OLD BC1",Image.fromarray(fast.astype(np.uint8))),("HQ BC1",decoded)]):
                preview.paste(img,(i*WIDTH,24));d.text((i*WIDTH+5,5),label,fill="white")
            preview.save(ROOT/"quality_comparison.png")
            photo=pack_photo(image);inspect_photo(photo)
            (ROOT/"quality_sample.img").write_bytes(photo)
    report=dict(cases=results,scope="RGB squared error and interpolation precision; not a claim about all perceptual quality",
        sse_fast=sum(r["baseline_sse"] for r in results),sse_hq=sum(r["hq_sse"] for r in results),
        interpolation4_mse=sum(r["scaler_4bit_mse_vs_exact"] for r in results)/len(results),
        interpolation8_mse=sum(r["scaler_8bit_mse_vs_exact"] for r in results)/len(results))
    (ROOT/"quality_benchmark.json").write_text(json.dumps(report,indent=2)+"\n")
    assert report["interpolation8_mse"]<report["interpolation4_mse"]
    print("PASS all BC1 blocks guarded, independent decoder check, eight-bit interpolation error reduced")
if __name__=="__main__":main()
