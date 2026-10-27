"""Read-only verification of the two replacement clips against desktop video.mp4."""
import hashlib
import json
import subprocess
from pathlib import Path

from PIL import Image
import mp4_to_tf_video as fmt
from hd_media import encode_bc1

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT.parent.parent / 'video.mp4'
FFMPEG = fmt.executable('ffmpeg')
results = []
for name, slot, start, seconds in [
    ('video01_first10s_6fps.bin', 1, 0, 10),
    ('video02_last15s_6fps.bin', 2, 95, 15),
]:
    path = ROOT / name
    info = fmt.inspect(path)
    assert info['slot'] == slot and info['fps'] == 6
    assert info['frames'] == seconds * 6 and info['duration_seconds'] == seconds
    command = [FFMPEG, '-v', 'error', '-nostdin', '-ss', str(start), '-i', str(SOURCE)]
    pcm = subprocess.run(command + ['-map', '0:a:0', '-vn', '-ac', '1', '-ar', '48000',
        '-af', f'aresample=48000:first_pts=0,apad,atrim=end_sample={seconds*48000},asetpts=PTS-STARTPTS',
        '-t', str(seconds), '-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1'],
        capture_output=True, check=True).stdout
    assert len(pcm) == seconds * 48000 * 2
    fit = ('scale=iw*sar:ih,setsar=1,fps=6,'
           'scale=640:480:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,'
           'pad=640:480:(ow-iw)/2:(oh-ih)/2:color=black,'
           f"select='eq(n,0)+eq(n,{info['frames']-1})'")
    rgb = subprocess.run(command + ['-t', str(seconds), '-map', '0:v:0', '-an', '-vf', fit,
        '-fps_mode', 'passthrough', '-frames:v', '2', '-pix_fmt', 'rgb24', '-f', 'rawvideo', 'pipe:1'],
        capture_output=True, check=True).stdout
    assert len(rgb) == 2 * fmt.FRAME_BYTES
    endpoints = {0: encode_bc1(Image.frombytes('RGB', (640, 480), rgb[:fmt.FRAME_BYTES])),
                 info['frames']-1: encode_bc1(Image.frombytes('RGB', (640, 480), rgb[fmt.FRAME_BYTES:]))}
    with path.open('rb') as file:
        file.seek(512)
        for index in range(info['frames']):
            record = file.read(info['record_sectors'] * 512)
            assert record[153600:169600] == pcm[index*16000:(index+1)*16000], (name, index, 'PCM')
            assert record[169600:] == bytes(384), (name, index, 'audio padding')
            if index in endpoints:
                assert record[:153600] == endpoints[index], (name, index, 'video endpoint')
        assert file.read() == b''
    info.update(source_start_seconds=start, source_end_seconds=start+seconds,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                verified='header CRC, slot, all PCM bytes/padding, first/last HQ BC1 frames')
    results.append(info)
    print('PASS', name, json.dumps(info), flush=True)
(ROOT/'replacement_media_verified_20261027.json').write_text(
    json.dumps(results, indent=2), encoding='utf-8')
