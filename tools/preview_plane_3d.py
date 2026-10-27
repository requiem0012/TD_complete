"""CPU reference rendering of the RTL plane effect; no FPGA/card writes.

Generates diagnostic previews, not input media and not a hardware capture.
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from hd_media import decode_preview

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'plane_3d_preview'
OUT.mkdir(exist_ok=True)
a=np.asarray(decode_preview((ROOT/'image1_native.img').read_bytes()[512:]),dtype=np.int32)
b=np.asarray(decode_preview((ROOT/'image2_native.img').read_bytes()[512:]),dtype=np.int32)
y,x=np.indices((480,640))

def frame(p):
    if p==0:return Image.fromarray(a.astype('uint8'))
    if p>=640:return Image.fromarray(b.astype('uint8'))
    fold=min(p,320);flight=max(0,(p-320)*2)
    u=x-(320+flight);v=y-(240-flight//2-flight//4)+(u*min(fold,256)>>9)
    av=np.abs(v);left=-320+fold//2
    span=640-fold if p<320 else 320-flight//4
    diagonal=av*fold//128;distance=u-left
    paper=(span>diagonal)&(u>=left)&(distance<span-diagonal)
    paper &= ~((fold>=256)&(distance<32)&(av<8))
    su=u-12;sv=v-22;sdistance=su-left;sdiag=np.abs(sv)*fold//128
    shadow=(fold>=128)&(span>sdiag)&(su>=left)&(sdistance<span-sdiag)
    shadow &= ~((fold>=256)&(sdistance<32)&(np.abs(sv)<8))
    mx=np.clip(320+u+(u*min(fold,256)>>8),0,639)
    mx=np.where((fold>=80)&(v< -4),639-mx,mx)
    texture=a[y,mx];result=b.copy()
    result[shadow&~paper] >>= 1
    shade=np.zeros_like(x)
    if fold>=80:shade=np.where(v<0,1,2)
    shade=np.where((fold>=192)&(v>0)&(av>(span>>3))&(distance<(span>>1)),5,shade)
    shade=np.where((fold>=160)&(av<3),3,shade)
    shade=np.where((fold>=192)&(span-diagonal-distance<3),6,shade)
    tinted=texture.copy()
    for code,values in ((1,texture-(texture>>2)+48),(2,(texture>>1)+(texture>>3)),
                        (3,np.full_like(texture,245)),(5,(texture>>2)+168),
                        (6,(texture>>2)+192)):
        tinted[shade==code]=values[shade==code]
    result[paper]=tinted[paper]
    return Image.fromarray(result.astype('uint8'))

phases=[0,80,160,240,320,360,400,440,480,560]
sheet=Image.new('RGB',(5*320,2*264),'#202630')
draw=ImageDraw.Draw(sheet)
for n,p in enumerate(phases):
    xx=(n%5)*320;yy=(n//5)*264
    sheet.paste(frame(p).resize((320,240)),(xx,yy))
    draw.text((xx+8,yy+244),f'progress {p}/640',fill='white')
sheet.save(OUT/'plane_3d_contact.png')
images=[frame(p).resize((480,360)) for p in range(0,641,8)]
images[0].save(OUT/'plane_3d_reference.gif',save_all=True,append_images=images[1:],
               duration=19,loop=0)
print('Reference previews:',OUT)
