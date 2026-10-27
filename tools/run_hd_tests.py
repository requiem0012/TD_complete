"""HD regression runner; writes only generated test fixtures under tools/tests."""
from pathlib import Path
import os, random, struct, subprocess, sys, zlib
from PIL import Image
from hd_media import *
import mp4_to_tf_video as media

ROOT=Path(__file__).resolve().parent
TEST=ROOT/"tests"
RTL=ROOT.parent/"source_code/rtl"
BIN=ROOT/".test_deps/icarus/ucrt64/bin"
ENV=os.environ.copy();ENV["PATH"]=str(BIN)+os.pathsep+ENV.get("PATH","")
def sim(name, files, models=False, variants=((),)):
    target=TEST/(name+".vvp")
    sources=[TEST/(name+".v")]
    if models:sources+=[TEST/"framebuffer_video_tb.v"]
    cmd=[str(BIN/"iverilog.exe"),"-g2012","-s",name,"-o",str(target)]
    subprocess.run(cmd+list(map(str,sources))+[str(RTL/x) for x in files],check=True,env=ENV,cwd=TEST)
    for args in variants:
        subprocess.run([str(BIN/"vvp.exe"),str(target),*args],check=True,env=ENV,cwd=TEST,timeout=600)

def expand(v):
    return ((v>>11)*255//31, ((v>>5)&63)*255//63, (v&31)*255//31)
# BC1 expands the endpoint bit fields by replication, not division.
def endpoint(v):
    r,g,b=v>>11,(v>>5)&63,v&31
    return ((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2))
def decode(data):
    pixels=[None]*(WIDTH*HEIGHT)
    for by in range(HEIGHT//4):
        for bx in range(WIDTH//4):
            c0,c1,indices=struct.unpack_from("<HHI",data,(by*(WIDTH//4)+bx)*8)
            a,b=endpoint(c0),endpoint(c1)
            colors=[a,b]
            colors += [tuple((2*x+y)//3 for x,y in zip(a,b)),tuple((x+2*y)//3 for x,y in zip(a,b))] if c0>c1 else [tuple((x+y)//2 for x,y in zip(a,b)),(0,0,0)]
            for y in range(4):
                for x in range(4):
                    pixels[(by*4+y)*WIDTH+bx*4+x]=colors[(indices>>(2*(y*4+x)))&3]
    return pixels
def fixtures():
    payload=random.Random(20261019).randbytes(PAYLOAD_BYTES)
    prefix=struct.pack("<8s5I",PHOTO_MAGIC,2,WIDTH,HEIGHT,PAYLOAD_BYTES,zlib.crc32(payload))
    photo=(prefix+struct.pack("<I",zlib.crc32(prefix))).ljust(512,b"\0")+payload
    (TEST/"hd_photo.hex").write_text("\n".join(f"{v:02x}" for v in photo.ljust(65536,b"\0"))+"\n")
    words=struct.unpack("<%dH"%(len(payload)//2),payload)
    (TEST/"hd_words.hex").write_text("\n".join(f"{x:04x}" for x in words)+"\n")
    alternate=struct.pack("<32448H",*[w^0x55aa for w in words])
    for suffix,stream in [("",payload),("_b",alternate)]:
        px=decode(stream)
        with (TEST/f"hd_pixels{suffix}.hex").open("w") as out:
            for y in range(480):
                yf=y*832//5;sy,fy=yf>>8,yf&255;ny=min(sy+1,HEIGHT-1)
                for x in range(640):
                    xf=x*832//5;sx,fx=xf>>8,xf&255;nx=min(sx+1,WIDTH-1)
                    a,b,c,d=[px[yy*WIDTH+xx] for xx,yy in [(sx,sy),(nx,sy),(sx,ny),(nx,ny)]]
                    rgb=tuple(((a[k]*(256-fx)+b[k]*fx)*(256-fy)+(c[k]*(256-fx)+d[k]*fx)*fy+32768)>>16 for k in range(3))
                    out.write("%02x%02x%02x\n"%rgb)
    # Actual Pillow encoder, independently decoded block ordering, portrait bars.
    import bmp2raw
    for size in [(1,1),(900,1600),(1920,1080),(416,312),(17,29)]:
        image=bmp2raw.resize_image(Image.new("RGB",size,"red"),"contain","black")
        packed=pack_photo(image);inspect_photo(packed)
        assert len(packed)==65408 and len(packed)<=65536
        decoded=decode(packed[512:])
        pil=list(decode_preview(packed[512:]).get_flattened_data())
        assert max(abs(a-b) for p,q in zip(decoded,pil) for a,b in zip(p,q))<=1
        if size[0]<size[1]:
            assert max(decoded[HEIGHT//2*WIDTH])==0
        broken=bytearray(packed);broken[-1]^=1
        try:inspect_photo(broken)
        except ValueError:pass
        else:raise AssertionError("corrupted photo accepted")
    for slot in [1,2,32]:
        header=media.make_header(2,slot)
        assert header[:8]==b"HXVIDEO2" and struct.unpack_from("<I",header,8)[0]==2
        assert zlib.crc32(header[:52])==struct.unpack_from("<I",header,52)[0]
    for slot,frames in [(1,2),(32,2),(1,1)]:
        clip=bytearray(media.make_header(frames,slot))
        for f in range(frames):
            v=struct.pack("<32448H",*[i^(0x55aa if f else 0) for i in range(32448)])
            a=struct.pack("<6000H",*[(i*137+f*8191)&65535 for i in range(6000)])
            clip.extend(v.ljust(65536,b"\0"));clip.extend(a.ljust(12288,b"\0"))
        suffix="_single" if frames==1 else ""
        (TEST/f"hd_slot{slot}{suffix}.hex").write_text("\n".join(f"{v:02x}" for v in clip)+"\n")
    print("PASS format/BC1/Pillow/contain/EXIF-ready resize/header and payload CRC")
    for name in ("red","green","blue"):
        data=pack_photo(Image.new("RGB",(WIDTH,HEIGHT),"lime" if name=="green" else name)).ljust(65536,b"\0")
        (TEST/f"hd_{name}.hex").write_text("\n".join(f"{v:02x}" for v in data)+"\n")
def main():
    fixtures()
    sim("ui_controls_tb",["tf_hdmi_top.v"])
    sim("media_osd_tb",["tf_hdmi_top.v"])
    sim("ui_settings_top_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v","sd_card_top.v","spi_master.v"],True)
    sim("hd_render_tb",["framebuffer.v","vga_disp.v"],True)
    sim("hd_presenter_tb",["framebuffer.v"],True, ((),("+FAULT=1",)))
    sim("hd_photo_tb",["sd_loader.v"],False,((),("+BAD=1",)))
    sim("hd_video_player_tb",["sd_loader.v","framebuffer.v"],True,
        ((),("+ONCE=1","+REPLAY=1"),("+SINGLE=1",),("+SINGLE=1","+ONCE=1"),
         ("+PAUSE=1",),("+STALL=1",),("+SLOT=31",),("+BAD=1",),("+BAD=2",),
         ("+BAD=3",),("+BAD=4",),("+PRESENT=1",)))
    sim("photo_slide_tb",["tf_hdmi_top.v"])
    sim("photo_autoplay_tb",["tf_hdmi_top.v"])
    sim("hd_photo_hold_top_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v","sd_card_top.v","spi_master.v"],True)
    sim("video_controls_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v","sd_card_top.v","spi_master.v"],True)
    sim("ui_overlay_tb",["tf_hdmi_top.v","sd_loader.v","framebuffer.v","vga_disp.v","sd_card_top.v","spi_master.v"],True)
    sim("sd_capacity_tb",["sd_card_top.v","spi_master.v"],False,((),("+CACHE=1",)))
    sim("sd_spi_pins_tb",["sd_card_top.v","spi_master.v"])
    print("PASS HD regressions (behavioral RAM model; silicon not tested)")
if __name__=="__main__":main()
