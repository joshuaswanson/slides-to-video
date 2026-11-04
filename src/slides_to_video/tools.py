from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


class PipelineError(RuntimeError):
    pass


def run_tool(cmd: list[str], *, stdout_bytes: bool = False) -> bytes:
    """Run ffmpeg/pdftoppm/etc. and raise PipelineError with stderr on failure."""
    if shutil.which(cmd[0]) is None:
        raise PipelineError(f"{cmd[0]} not found. Install it and make sure it is on PATH.")
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode(errors="replace").strip().splitlines()
        tail = "\n".join(stderr[-15:])
        raise PipelineError(f"{cmd[0]} failed (exit {result.returncode}):\n{tail}")
    return result.stdout if stdout_bytes else b""


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()[:16]


def text_hash(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:16]


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.replace(tmp, path)
