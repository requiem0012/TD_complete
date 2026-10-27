"""Format, boundaries and actual FFmpeg smoke tests; also emits RTL fixtures."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

import mp4_to_tf_video as media

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / ".test_deps"))


def fixtures():
    target = ROOT / "tests"
    target.mkdir(exist_ok=True)
    for slot in (1,32):
        payload = bytearray(media.make_header(2, slot))
        for frame in range(2):
            video = b"".join(struct.pack("<H", i ^ (0x55AA if frame else 0)) for i in range(30000))
            audio = b"".join(struct.pack("<H", (i*137+frame*8191)&65535) for i in range(6000))
            payload.extend(video.ljust(65536,b"\0"))
            payload.extend(audio.ljust(12288,b"\0"))
        (target / f"slot{slot}.hex").write_text("\n".join(f"{b:02x}" for b in payload)+"\n", encoding="ascii")
        if slot==1:
            single=media.make_header(1,1)+payload[512:512+77824]
            (target/"slot1_single.hex").write_text("\n".join(f"{b:02x}" for b in single)+"\n",encoding="ascii")
    images=b"".join((ROOT/f"image{i}.img").read_bytes() for i in range(1,5))
    (target/"images.hex").write_text("\n".join(f"{b:02x}" for b in images)+"\n",encoding="ascii")


class FormatTests(unittest.TestCase):
    def test_layout(self):
        for count in (9437184, 15728640, 16777216, 41943040, 67108864, 125042688, 2**32):
            slots = media.layout(count)
            self.assertEqual(len(slots),min(32,(count-8388608)//1048576))
            self.assertEqual(slots[0]["lba"],8388608)
            self.assertLessEqual(slots[-1]["end_lba_exclusive"],count)
            for i,s in enumerate(slots):
                self.assertEqual(s["end_lba_exclusive"]-s["lba"],1048576)
                if i:self.assertEqual(s["lba"],slots[i-1]["end_lba_exclusive"])
        for count in (0,8388608,9437183,2**32+1):
            with self.assertRaises(ValueError):media.layout(count)
        self.assertEqual(media.slot_layout(9437184,1)["byte_offset"],0x100000000)
        with self.assertRaises(ValueError):media.slot_layout(9437184,2)
        self.assertEqual(media.slot_layout(41943040,32)["end_lba_exclusive"],41943040)
        with self.assertRaises(ValueError):media.slot_layout(41943039,32)

    def test_headers(self):
        for slot in range(1,33):
            h = media.make_header(media.MAX_FRAMES,slot)
            self.assertEqual(len(h),512)
            self.assertEqual(struct.unpack_from("<I",h,48)[0],slot-1)
            self.assertEqual(struct.unpack_from("<I",h,52)[0],zlib.crc32(h[:52]))
        self.assertLessEqual(512+media.MAX_FRAMES*media.RECORD_BYTES,media.SLOT_BYTES)
        self.assertGreater(512+(media.MAX_FRAMES+1)*media.RECORD_BYTES,media.SLOT_BYTES)

    def test_original_image_files(self):
        for i,crc in enumerate((0x57FAEB18,0xE1BFE37F,0xE0A51CA4,0x1325981A),1):
            data=(ROOT/f"image{i}.img").read_bytes()
            self.assertEqual(len(data),60000)
            self.assertEqual(zlib.crc32(data),crc)

    def test_inspect_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp)/"slot.bin"
            raw = media.make_header(1,1)+bytes(media.RECORD_BYTES)
            file.write_bytes(raw)
            self.assertEqual(media.inspect(file)["frames"],1)
            file.write_bytes(raw[:-1])
            with self.assertRaises(ValueError):media.inspect(file)
            bad=bytearray(raw);bad[32]^=1;file.write_bytes(bad)
            with self.assertRaises(ValueError):media.inspect(file)

    def test_ffmpeg_actual_conversion(self):
        try:
            import imageio_ffmpeg
        except ImportError:
            self.skipTest("Optional portable FFmpeg not installed")
        exe=imageio_ffmpeg.get_ffmpeg_exe()
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp)
            for sound in (True,False):
                source=temp/f"input{sound}.mp4";dest=temp/f"slot{sound}.bin"
                cmd=[exe,"-v","error","-nostdin","-y","-f","lavfi","-i","color=c=red:s=320x240:r=8:d=0.5"]
                if sound:cmd += ["-f","lavfi","-i","sine=frequency=997:sample_rate=48000:duration=0.5"]
                cmd += ["-c:v","libx264","-pix_fmt","yuv420p"]
                if sound:cmd += ["-c:a","aac","-shortest"]
                subprocess.run(cmd+[str(source)],check=True,capture_output=True)
                subprocess.run([sys.executable,str(ROOT/"mp4_to_tf_video.py"),str(source),str(dest),
                    "--slot","32","--card-sectors","67108864"],check=True,capture_output=True)
                info=media.inspect(dest);self.assertEqual(info["frames"],4)
                raw=dest.read_bytes()
                first=struct.unpack_from("<H",raw,512)[0]
                self.assertGreater(first>>11,28);self.assertLess(first&31,3)
                pcm=raw[512+65536:512+65536+12000]
                self.assertEqual(any(pcm),sound)
                for n in range(4):
                    start=512+n*media.RECORD_BYTES
                    self.assertFalse(any(raw[start+60000:start+65536]))
                    self.assertFalse(any(raw[start+65536+12000:start+media.RECORD_BYTES]))
                manifest=json.loads(dest.with_suffix(".bin.json").read_text())
                self.assertEqual(manifest["lba"],8388608+31*1048576)


if __name__=="__main__":
    fixtures()
    unittest.main(verbosity=2)
