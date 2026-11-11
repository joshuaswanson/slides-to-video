"""Speech generation for one slide, and the ambient noise used for pauses."""

from __future__ import annotations

import re
from pathlib import Path

import numpy as np

from .tts_engines import TTSEngine

PAUSE_RE = re.compile(r"\[pause(?:\s+(\d+(?:\.\d+)?|\.\d+))?\]")
DEFAULT_INLINE_PAUSE = 0.5
DEFAULT_SAMPLE_RATE = 24000
AMBIENT_RMS_THRESHOLD = 0.01


def split_pauses(text: str) -> list[str | float]:
    """Split narration into text segments and pause durations in seconds."""
    items: list[str | float] = []
    for i, piece in enumerate(PAUSE_RE.split(text)):
        if i % 2 == 0:
            if piece.strip():
                items.append(piece.strip())
        else:
            items.append(float(piece) if piece else DEFAULT_INLINE_PAUSE)
    return items


def synthesize(text: str, engine: TTSEngine, voice_path: Path, language: str) -> tuple[np.ndarray, int]:
    """Generate narration, inserting silence for [pause] markers."""
    items = split_pauses(" ".join(text.split()))
    speech = {
        i: engine.generate(item, voice_path, language=language)
        for i, item in enumerate(items) if isinstance(item, str)
    }
    rates = {sr for _, sr in speech.values()}
    if len(rates) > 1:
        raise RuntimeError(f"Engine returned mixed sample rates {sorted(rates)}")
    sample_rate = rates.pop() if rates else DEFAULT_SAMPLE_RATE
    pieces = [
        speech[i][0] if i in speech else np.zeros(round(item * sample_rate), dtype=np.float32)
        for i, item in enumerate(items)
    ]
    wav = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)
    return wav.astype(np.float32), sample_rate


def make_ambient_loop(engine: TTSEngine, voice_path: Path, language: str) -> tuple[np.ndarray, int]:
    """Capture the model's background noise by feeding it whitespace.

    Keeps the audio before the first speech-like window and crossfades the end
    into the start so the result tiles without a click.
    """
    data, sr = engine.generate(" " * 20, voice_path, language=language)
    window = int(0.05 * sr)
    end = len(data)
    for start in range(0, len(data) - window, window):
        if np.sqrt(np.mean(data[start:start + window] ** 2)) > AMBIENT_RMS_THRESHOLD:
            end = start
            break
    clean = data[:max(end, int(0.1 * sr))].astype(np.float32)

    fade = int(0.02 * sr)
    if len(clean) <= 2 * fade:
        return clean, sr
    ramp = np.linspace(0, 1, fade, dtype=np.float32)
    loop = clean[:-fade].copy()
    loop[:fade] = clean[-fade:] * (1 - ramp) + clean[:fade] * ramp
    return loop, sr
