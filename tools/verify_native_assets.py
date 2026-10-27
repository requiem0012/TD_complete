"""Verify native media layout, image CRCs, every BC1 frame, and source PCM."""
from pathlib import Path
import hashlib,json,subprocess
from PIL import Image
from hd_media import inspect_photo,decode_preview
import mp4_to_tf_video as fmt

ROOT=Path(__file__).resolve().parent
combined=(ROOT/'TF_NATIVE_4images.img').read_bytes()
assert len(combined)==1048576
for n in range(1,5):
    photo=(ROOT/f'image{n}_native.img').read_bytes()
    inspect_photo(photo)
    slot=combined[(n-1)*262144:n*262144]
    assert slot[:len(photo)]==photo and not any(slot[len(photo):])
    assert decode_preview(photo[512:]).size==(640,480)
print('PASS four HXIMAGE3 photos, CRC32, fixed 512-sector slots and zero padding',flush=True)
for name,source in [('demo0_native.bin','demo0.mp4'),('demo1_native_sample.bin','demo1.mp4'),
                    ('demo0_6fps.bin','demo0.mp4'),('demo1_6fps_sample.bin','demo1.mp4')]:
    path=ROOT/name;info=fmt.inspect(path);pcm=hashlib.sha256()
    with path.open('rb') as f:
        f.seek(512)
        for _ in range(info['frames']):
            record=f.read(info['record_sectors']*512)
            assert decode_preview(record[:153600]).size==(640,480)
            end_audio=153600+info['samples']*2
            pcm.update(record[153600:end_audio])
            assert not any(record[end_audio:])
    result=subprocess.run([fmt.executable('ffmpeg'),'-v','error','-nostdin','-i',str(ROOT/source),
        '-map','0:a:0','-vn','-ac','1','-ar','48000','-af',
        f'aresample=48000:first_pts=0,apad,atrim=end_sample={info["frames"]*info["samples"]},asetpts=PTS-STARTPTS',
        '-t',str(info['duration_seconds']),
        '-c:a','pcm_s16le','-f','s16le','-'],check=True,capture_output=True)
    assert len(result.stdout)==info['frames']*info['samples']*2
    assert hashlib.sha256(result.stdout).digest()==pcm.digest()
    print(f'PASS {name}: {info["frames"]} frames, every BC1 frame decoded, exact source PCM SHA256={pcm.hexdigest()}',flush=True)
