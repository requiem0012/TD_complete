#!/usr/bin/env python3
"""Convert PC videos to HXVIDEO3 raw TF-slot data, never write a physical disk.

Examples:
  python mp4_to_tf_video.py film.mp4 video01.bin --slot 1
  python mp4_to_tf_video.py film.mp4 video32.bin --slot 32 --card-bytes 64021856256
  python mp4_to_tf_video.py --layout-only --card-sectors 125042688
  python mp4_to_tf_video.py --inspect video01.bin

Requires Pillow >=12, FFmpeg and FFprobe on PATH, or --ffmpeg /path/to/ffmpeg.exe.
Output is media .bin data, not the FPGA configuration .bit file.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import sys
import zlib

SECTOR = 512
SLOT_BYTES = 512 * 1024 * 1024
SLOT_SECTORS = SLOT_BYTES // SECTOR
SLOTS = 32
REGION_SECTORS = SLOTS * SLOT_SECTORS
VIDEO_BASE_SECTORS = 8388608  # Absolute 4 GiB, independent of card capacity.
from hd_media import WIDTH, HEIGHT, PAYLOAD_BYTES, encode_bc1
from PIL import Image
FPS, RATE = 6, 48000
SAMPLES = RATE // FPS
VIDEO_SECTORS, AUDIO_SECTORS = 300, 32
RECORD_SECTORS = VIDEO_SECTORS + AUDIO_SECTORS
FRAME_BYTES = WIDTH * HEIGHT * 3  # temporary RGB24 decoded frames
RECORD_BYTES = RECORD_SECTORS * SECTOR
MAX_FRAMES = (SLOT_SECTORS - 1) // RECORD_SECTORS
MAGIC = b"HXVIDEO3"


def layout(card_sectors: int) -> list[dict]:
    if card_sectors < VIDEO_BASE_SECTORS + SLOT_SECTORS or card_sectors > 2**32:
        raise ValueError("Card must fit at least one full 512 MiB slot after 4 GiB (SDHC/SDXC)")
    base = VIDEO_BASE_SECTORS
    count = min(SLOTS, (card_sectors - base) // SLOT_SECTORS)
    return [dict(slot=i + 1, lba=base + i * SLOT_SECTORS,
                 byte_offset=(base + i * SLOT_SECTORS) * SECTOR,
                 end_lba_exclusive=base + (i + 1) * SLOT_SECTORS)
            for i in range(count)]


def slot_layout(card_sectors: int, slot: int) -> dict:
    slots = layout(card_sectors)
    if not 1 <= slot <= len(slots):
        raise ValueError("Selected full slot exceeds card capacity")
    return slots[slot-1]


def geometry(fps: int) -> dict:
    if fps not in (4, 6):
        raise ValueError("Supported frame rates: 4 or 6")
    samples = RATE // fps
    audio = (samples * 2 + SECTOR - 1) // SECTOR
    record = VIDEO_SECTORS + audio
    return dict(fps=fps, samples=samples, audio_sectors=audio,
                record_sectors=record, max_frames=(SLOT_SECTORS-1)//record)


def make_header(frames: int, slot: int, fps: int = FPS) -> bytes:
    g = geometry(fps)
    if not 1 <= frames <= g['max_frames'] or not 1 <= slot <= SLOTS:
        raise ValueError("Invalid frame count or slot number")
    prefix = struct.pack("<8s11I", MAGIC, 3, WIDTH, HEIGHT, fps, RATE, g['samples'],
                         frames, g['record_sectors'], VIDEO_SECTORS, g['audio_sectors'], slot - 1)
    return (prefix + struct.pack("<I", zlib.crc32(prefix))).ljust(SECTOR, b"\0")


def inspect(path: Path) -> dict:
    with path.open("rb") as file:
        header = file.read(SECTOR)
    if len(header) != SECTOR:
        raise ValueError("Short header")
    fields = struct.unpack("<8s12I", header[:56])
    g = geometry(fields[4])
    if fields[:7] != (MAGIC, 3, WIDTH, HEIGHT, g['fps'], RATE, g['samples']):
        raise ValueError("Unsupported media format")
    frames, record, video, audio, slot, crc = fields[7:]
    if (record, video, audio) != (g['record_sectors'], VIDEO_SECTORS, g['audio_sectors']):
        raise ValueError("Invalid record layout")
    if not 1 <= frames <= g['max_frames'] or not 0 <= slot < SLOTS:
        raise ValueError("Invalid length or slot")
    if zlib.crc32(header[:52]) != crc:
        raise ValueError("Header CRC32 mismatch")
    size = SECTOR + frames * record * SECTOR
    if path.stat().st_size != size or size > SLOT_BYTES:
        raise ValueError("File length does not match header / slot limit")
    return dict(format="HXVIDEO3", slot=slot + 1, frames=frames, **g,
                duration_seconds=frames / g['fps'], bytes=size)


def executable(name: str, supplied: str | None = None) -> str:
    candidate = supplied or shutil.which(name)
    if not candidate and name == "ffmpeg":
        # Optional portable copy used by the project's conversion regression tests.
        local = Path(__file__).parent / "ffmpeg.exe"
        copies = sorted((Path(__file__).parent / ".test_deps/imageio_ffmpeg/binaries").glob("ffmpeg*.exe"))
        candidate = str(local) if local.is_file() else (str(copies[-1]) if copies else None)
    if not candidate:
        raise ValueError(f"{name} not found; install FFmpeg or use --ffmpeg/--ffprobe")
    return str(candidate)


def run(args: list[str]) -> None:
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", errors="replace")[-5000:])


def convert(args: argparse.Namespace) -> dict:
    g = geometry(args.fps)
    fps, samples = g['fps'], g['samples']
    max_frames, audio_sectors = g['max_frames'], g['audio_sectors']
    source, output = Path(args.input).resolve(), Path(args.output).resolve()
    if not source.is_file():
        raise ValueError(f"Input does not exist: {source}")
    if source == output or output.suffix.lower() == ".bit":
        raise ValueError("Use a separate .bin output; .bit is reserved for FPGA configuration")
    if output.exists() and not args.force:
        raise ValueError("Output exists; use --force to replace it")
    manifest = output.with_suffix(output.suffix + ".json")
    if manifest.exists() and not args.force:
        raise ValueError("Manifest already exists; use --force to replace it")
    if args.duration is not None and args.duration <= 0:
        raise ValueError("--duration must be positive")
    start = getattr(args, "start", 0.0)
    if start < 0:
        raise ValueError("--start must be nonnegative")
    ffmpeg = executable("ffmpeg", args.ffmpeg)
    probe_sibling = str(Path(ffmpeg).with_name("ffprobe" + Path(ffmpeg).suffix))
    ffprobe = args.ffprobe or (probe_sibling if Path(probe_sibling).is_file() else shutil.which("ffprobe"))
    if ffprobe:
        probe = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-of", "json", str(source)],
                               capture_output=True, text=True, encoding="utf-8", check=True)
        streams = json.loads(probe.stdout).get("streams", [])
        has_video = any(s.get("codec_type") == "video" for s in streams)
        has_audio = any(s.get("codec_type") == "audio" for s in streams)
    else:
        # Portable FFmpeg-only distributions can still enumerate streams.
        probe = subprocess.run([ffmpeg, "-hide_banner", "-nostdin", "-i", str(source)], capture_output=True)
        description = probe.stderr.decode("utf-8", errors="replace")
        has_video = bool(re.search(r"Stream .*Video:", description))
        has_audio = bool(re.search(r"Stream .*Audio:", description))
    if not has_video:
        raise ValueError("Input has no decodable video stream")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hxvideo_", dir=output.parent) as temp:
        temp = Path(temp)
        raw_v, raw_a, packed = temp / "video.rgb24", temp / "audio.pcm", temp / "slot.bin"
        common = [ffmpeg, "-v", "error", "-nostdin", "-y", "-ss", str(start), "-i", str(source)]
        duration = ["-t", str(args.duration)] if args.duration else []
        fit = (f"scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,"
               f"pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black")
        run(common + duration + ["-map", "0:v:0", "-an", "-vf", f"scale=iw*sar:ih,setsar=1,fps={fps},{fit}",
            "-frames:v", str(max_frames + 1), "-pix_fmt", "rgb24", "-f", "rawvideo", str(raw_v)])
        size = raw_v.stat().st_size
        frames = size // FRAME_BYTES
        if size % FRAME_BYTES or not frames:
            raise ValueError("No complete video frames were generated")
        if frames > max_frames:
            raise ValueError(f"Video exceeds 512 MiB slot ({max_frames/fps:.3f}s); shorten using --duration")
        if has_audio:
            run(common + ["-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(RATE),
                "-af", f"aresample={RATE}:first_pts=0,apad,atrim=end_sample={frames*samples},asetpts=PTS-STARTPTS",
                "-t", str(frames/fps), "-c:a", "pcm_s16le", "-f", "s16le", str(raw_a)])
        else:
            raw_a.touch()
        with raw_v.open("rb") as video, raw_a.open("rb") as audio, packed.open("wb") as target:
            target.write(make_header(frames, args.slot, fps))
            for frame_index in range(frames):
                rgb = video.read(FRAME_BYTES)
                if len(rgb) != FRAME_BYTES:
                    raise ValueError("Truncated video conversion")
                target.write(encode_bc1(Image.frombytes("RGB", (WIDTH, HEIGHT), rgb), quality=args.quality).ljust(VIDEO_SECTORS * SECTOR, b"\0"))
                pcm = audio.read(samples * 2)
                target.write(pcm.ljust(audio_sectors * SECTOR, b"\0"))
                if (frame_index+1)%32==0 or frame_index+1==frames:
                    print(f"Encoded {frame_index+1}/{frames} frames ({args.quality})",file=sys.stderr,flush=True)
        info = inspect(packed)
        info.update(input=str(source), output=str(output), source_start_seconds=start,
                    audio="48000Hz signed16 mono LE", encoder_quality=args.quality,
                    audio_alignment="first_pts=0, exact sample count", slot_bytes=SLOT_BYTES, region_bytes=REGION_SECTORS * SECTOR,
                    video_base_bytes=VIDEO_BASE_SECTORS * SECTOR,
                    lba_formula=f"{VIDEO_BASE_SECTORS} + {args.slot-1} * {SLOT_SECTORS}",
                    lba=VIDEO_BASE_SECTORS + (args.slot-1) * SLOT_SECTORS,
                    byte_offset=(VIDEO_BASE_SECTORS + (args.slot-1) * SLOT_SECTORS) * SECTOR,
                    note="Write raw bytes at the calculated offset; copying into a FAT folder does not work.")
        capacity = args.card_sectors
        if args.card_bytes is not None:
            if args.card_bytes % SECTOR:
                raise ValueError("Card byte capacity must be divisible by 512")
            capacity = args.card_bytes // SECTOR
        if capacity is not None:
            info.update(slot_layout(capacity, args.slot))
        os.replace(packed, output)
        manifest.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", nargs="?")
    parser.add_argument("output", nargs="?")
    parser.add_argument("--slot", type=int, choices=range(1,33), default=1, metavar="1..32")
    capacity = parser.add_mutually_exclusive_group()
    capacity.add_argument("--card-bytes", type=int)
    capacity.add_argument("--card-sectors", type=int)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--start", type=float, default=0.0, help="Accurate seek in seconds, applied to both video and audio")
    parser.add_argument("--fps", type=int, choices=(4, 6), default=FPS)
    parser.add_argument("--quality", choices=("hq", "fast"), default="hq")
    parser.add_argument("--ffmpeg")
    parser.add_argument("--ffprobe")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--layout-only", action="store_true")
    parser.add_argument("--inspect", type=Path)
    args = parser.parse_args()
    try:
        if args.inspect:
            info = inspect(args.inspect)
        elif args.layout_only:
            count = args.card_sectors
            if args.card_bytes is not None:
                if args.card_bytes % SECTOR:
                    raise ValueError("Card byte capacity must be divisible by 512")
                count = args.card_bytes // SECTOR
            if count is None:
                raise ValueError("Supply actual --card-bytes or --card-sectors")
            info = layout(count)
        else:
            if not args.input or not args.output:
                parser.error("Supply input video and output .bin")
            info = convert(args)
        print(json.dumps(info, ensure_ascii=False, indent=2))
        return 0
    except ImportError:
        parser.exit(1, "HQ needs NumPy: python -m pip install -r requirements_hd.txt (or --quality fast)\n")
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Error: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
