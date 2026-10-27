"""Read-only actual-file CRC regressions; generated test fingerprints stay local."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import mp4_to_tf_video as fmt

parser = argparse.ArgumentParser()
parser.add_argument("--media", default="demo0.bin")
parser.add_argument("--target", type=int)
parser.add_argument("--slow", action="store_true")
parser.add_argument("--once", action="store_true")
args = parser.parse_args()
media = (ROOT / args.media).resolve()
info = fmt.inspect(media)
vcrc, acrc = [], []
with media.open("rb") as source:
    source.seek(512)
    for frame in range(info["frames"]):
        record = source.read(fmt.RECORD_BYTES)
        vcrc.append(f"{zlib.crc32(record[:60000]):08x}\n")
        acrc.append(f"{zlib.crc32(record[65536:65536+12000]):08x}\n")
test = ROOT / "tests"
vpath, apath = test / (media.stem+"_vcrc.hex"), test / (media.stem+"_acrc.hex")
vpath.write_text("".join(vcrc), encoding="ascii")
apath.write_text("".join(acrc), encoding="ascii")
bin_dir = ROOT / ".test_deps/icarus/ucrt64/bin"
env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ.get("PATH", ""))
binary = test / "video_real_file_tb.vvp"
subprocess.run([str(bin_dir/"iverilog.exe"), "-g2012", "-s", "video_real_file_tb",
                "-o", str(binary), str(test/"video_real_file_tb.v"),
                str(ROOT.parent/"source_code/rtl/sd_loader.v")], check=True, env=env)
target = args.target or (info["frames"] if args.once else info["frames"]*2)
subprocess.run([str(bin_dir/"vvp.exe"), str(binary), f"+MEDIA={media}",
                f"+VCRC={vpath}", f"+ACRC={apath}", f"+FRAMES={info['frames']}",
                f"+TARGET={target}", f"+SLOT={info['slot']-1}",
                f"+SLOW={int(args.slow)}", f"+ONCE={int(args.once)}"], check=True, env=env,
               timeout=1200)
