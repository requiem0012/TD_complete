"""Unpack the already-downloaded MSYS2 Icarus packages into .test_deps.

Test support only. Does not download or install global software.
"""
from pathlib import Path
import sys
import tarfile
sys.path.insert(0, str(Path(__file__).parent / ".test_deps"))
import zstandard

root = Path(__file__).parent / ".test_deps"
for source in sorted(root.glob("*.pkg.tar.zst")):
    with source.open("rb") as compressed:
        with zstandard.ZstdDecompressor().stream_reader(compressed) as reader:
            with tarfile.open(fileobj=reader, mode="r|") as archive:
                archive.extractall(root / "icarus", filter="data")
print(root / "icarus" / "ucrt64" / "bin")
