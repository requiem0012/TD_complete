"""Native 640x480 tests. Never accesses a physical TF device."""
from pathlib import Path
import os, random, struct, subprocess, sys

ROOT=Path(__file__).resolve().parent
TEST=ROOT/'tests'
RTL=ROOT.parent/'source_code/rtl'
BIN=ROOT/'.test_deps/icarus/ucrt64/bin'
ENV=dict(os.environ,PATH=str(BIN)+os.pathsep+os.environ.get('PATH',''))

def fixture():
    for suffix,seed in [('a',20261021),('b',20261022)]:
        payload=random.Random(seed).randbytes(153600)
        words=struct.unpack('<76800H',payload)
        (TEST/f'native_{suffix}.hex').write_text('\n'.join(f'{w:04x}' for w in words)+'\n')
        pixels=[0]*307200
        def expand(v):
            r,g,b=v>>11,(v>>5)&63,v&31
            return ((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2))
        for by in range(120):
            for bx in range(160):
                c0,c1,indices=struct.unpack_from('<HHI',payload,(by*160+bx)*8)
                a,b=expand(c0),expand(c1)
                colors=[a,b]+([tuple((2*x+y)//3 for x,y in zip(a,b)),tuple((x+2*y)//3 for x,y in zip(a,b))] if c0>c1 else [tuple((x+y)//2 for x,y in zip(a,b)),(0,0,0)])
                for y in range(4):
                    for x in range(4):
                        r,g,b=colors[(indices>>(2*(y*4+x)))&3]
                        pixels[(by*4+y)*640+bx*4+x]=(r<<16)|(g<<8)|b
        (TEST/f'native_g{suffix}.hex').write_text('\n'.join(f'{p:06x}' for p in pixels)+'\n')

def sim(name,sources,args=(),model=False):
    output=TEST/(name+'.vvp')
    files=[TEST/(name+'.v')]+[RTL/s for s in sources]
    if model:files += [TEST/'native_sip_model.v',TEST/'IS42s32200.v']
    subprocess.run([str(BIN/'iverilog.exe'),'-g2012','-s',name,'-o',str(output),*map(str,files)],check=True,env=ENV,cwd=TEST)
    result=subprocess.run([str(BIN/'vvp.exe'),str(output),*args],capture_output=True,text=True,env=ENV,cwd=TEST,timeout=900)
    print(result.stdout,flush=True)
    if result.stderr:print(result.stderr,file=sys.stderr,flush=True)
    if result.returncode or 'ERROR:' in result.stdout or 'PASS' not in result.stdout:
        raise RuntimeError(name+' failed')

if __name__=='__main__':
    fixture()
    sim('native_memory_tb',['sdram_burst.v','sdram_media.v'],model=True)
    sim('native_memory_tb',['sdram_burst.v','sdram_media.v'],args=('+fault',),model=True)
