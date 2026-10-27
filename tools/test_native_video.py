"""Actual-file video/PCM CRC tests, including wrap and exact one-shot EOF."""
import argparse,zlib
from pathlib import Path
from run_native_tests import ROOT,TEST,sim
import mp4_to_tf_video as fmt

p=argparse.ArgumentParser()
p.add_argument('media')
p.add_argument('--once',action='store_true')
p.add_argument('--slow',action='store_true')
p.add_argument('--realtime',action='store_true',help='Measured sector latency and 48 kHz sample period')
p.add_argument('--target',type=int)
a=p.parse_args()
media=Path(a.media).resolve()
info=fmt.inspect(media)
vc,ac=[],[]
with media.open('rb') as f:
    f.seek(512)
    for _ in range(info['frames']):
        record=f.read(info['record_sectors']*512)
        vc.append(zlib.crc32(record[:153600]))
        ac.append(zlib.crc32(record[153600:153600+info['samples']*2]))
vpath=TEST/(media.stem+'_native_vcrc.hex')
apath=TEST/(media.stem+'_native_acrc.hex')
vpath.write_text('\n'.join(f'{c:08x}' for c in vc)+'\n')
apath.write_text('\n'.join(f'{c:08x}' for c in ac)+'\n')
target=info['frames'] if a.once else info['frames']*2+1
if a.target is not None:
    if a.target<1 or (a.once and a.target!=info['frames']):
        raise ValueError('Invalid target / one-shot sample count')
    target=a.target
sim('native_video_file_tb',['sd_loader.v'],args=(
    f'+MEDIA={media}',f'+VCRC={vpath}',f'+ACRC={apath}',
    f'+FRAMES={info["frames"]}',f'+TARGET={target}',f'+SLOT={info["slot"]-1}',
    f'+SAMPLES={info["samples"]}',f'+RECORD={info["record_sectors"]}',
    f'+AUDIO_SECTORS={info["audio_sectors"]}',
    f'+REALTIME={int(a.realtime)}',
    f'+ONCE={int(a.once)}',f'+SLOW={int(a.slow)}'))
