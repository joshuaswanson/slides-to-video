"""TTS worker for the Mac app, speaking JSON lines over stdin and stdout.

Each request is one JSON object per line with an "id" and a "cmd". Each reply
echoes the id and has "ok": true with results, or "ok": false with "error".
Audio travels as base64 of 16-bit little-endian mono PCM with a "sample_rate".

    {"id": 1, "cmd": "hello"}
    {"id": 2, "cmd": "load", "engine": "qwen3", "device": "cuda"}
    {"id": 3, "cmd": "set_voice", "wav_b64": "..."}
    {"id": 4, "cmd": "synthesize", "text": "Hello [pause] world", "language": "en"}
    {"id": 5, "cmd": "ambient", "language": "en"}

The same worker runs locally or on a remote GPU host through ssh.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import tempfile
import traceback
from pathlib import Path
from typing import IO

import numpy as np

from . import __version__
from .speech import make_ambient_loop, synthesize
from .tts_engines import ENGINES, LANGUAGES, TTSEngine, check_language, get_engine

PROTOCOL_VERSION = 1


def encode_pcm16(samples: np.ndarray) -> str:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2")
    return base64.b64encode(pcm.tobytes()).decode("ascii")


def available_devices() -> list[str]:
    try:
        import torch
    except ImportError:
        return ["cpu"]
    devices = [f"cuda:{i}" for i in range(torch.cuda.device_count())]
    if torch.backends.mps.is_available():
        devices.append("mps")
    return devices + ["cpu"]


class Worker:
    def __init__(self) -> None:
        self.engine: TTSEngine | None = None
        self.voice_dir = Path(tempfile.mkdtemp(prefix="s2v-worker-"))
        self.voice_path: Path | None = None

    def handle(self, request: dict) -> dict:
        command = request.get("cmd")
        handler = getattr(self, f"cmd_{command}", None)
        if handler is None:
            raise ValueError(f"Unknown command {command!r}")
        return handler(request)

    def cmd_hello(self, _: dict) -> dict:
        return {
            "protocol": PROTOCOL_VERSION,
            "version": __version__,
            "engines": sorted(ENGINES),
            "languages": LANGUAGES,
            "devices": available_devices(),
        }

    def cmd_load(self, request: dict) -> dict:
        engine = get_engine(request["engine"])
        engine.load(request.get("device", "cuda"))
        self.engine = engine
        return {"engine": engine.name}

    def cmd_set_voice(self, request: dict) -> dict:
        path = self.voice_dir / "voice.wav"
        path.write_bytes(base64.b64decode(request["wav_b64"]))
        self.voice_path = path
        return {"voice_hash": hashlib.sha256(path.read_bytes()).hexdigest()[:16]}

    def _ready(self, language: str) -> tuple[TTSEngine, Path]:
        if self.engine is None:
            raise RuntimeError("No engine loaded. Send a load command first.")
        if self.voice_path is None:
            raise RuntimeError("No voice sample set. Send a set_voice command first.")
        check_language(self.engine.name, language)
        return self.engine, self.voice_path

    def cmd_synthesize(self, request: dict) -> dict:
        language = request.get("language", "en")
        engine, voice = self._ready(language)
        wav, sr = synthesize(request["text"], engine, voice, language)
        return {"sample_rate": sr, "pcm16_b64": encode_pcm16(wav)}

    def cmd_ambient(self, request: dict) -> dict:
        language = request.get("language", "en")
        engine, voice = self._ready(language)
        loop, sr = make_ambient_loop(engine, voice, language)
        return {"sample_rate": sr, "pcm16_b64": encode_pcm16(loop)}


def serve(stdin: IO[str], stdout: IO[str], worker: Worker | None = None) -> None:
    worker = worker or Worker()
    for line in stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            reply = {"id": request_id, "ok": True, **worker.handle(request)}
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            reply = {"id": request_id, "ok": False, "error": f"{type(e).__name__}: {e}"}
        stdout.write(json.dumps(reply) + "\n")
        stdout.flush()


def main() -> None:
    # Model libraries print to stdout. Keep the real stdout for protocol replies
    # and send everything else written to fd 1 to stderr.
    protocol_out = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    print(f"slides-to-video worker {__version__} ready", file=sys.stderr, flush=True)
    serve(sys.stdin, protocol_out)


if __name__ == "__main__":
    main()
