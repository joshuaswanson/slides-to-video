from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from slides_to_video import tts_engines

SR = 24000


class FakeEngine(tts_engines.TTSEngine):
    """Deterministic stand-in for a TTS model: 0.1 s of tone per word."""

    name = "fake"

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.device = None

    def load(self, device: str) -> None:
        self.device = device

    def generate(self, text, voice_wav_path, language="en"):
        self.calls.append(text)
        if not text.strip():
            t = np.arange(SR) / SR
            hiss = 0.003 * np.sin(2 * np.pi * 37.3 * t)
            burst = 0.5 * np.ones(int(0.3 * SR))
            return np.concatenate([hiss, burst]).astype(np.float32), SR
        n = int(0.1 * SR) * len(text.split())
        t = np.arange(n) / SR
        return (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32), SR


@pytest.fixture
def fake_engine(monkeypatch):
    monkeypatch.setitem(tts_engines.ENGINES, "fake", FakeEngine)
    return FakeEngine


@pytest.fixture
def voice_wav(tmp_path) -> Path:
    path = tmp_path / "voice_in.wav"
    t = np.arange(SR) / SR
    sf.write(str(path), (0.2 * np.sin(2 * np.pi * 180 * t)).astype(np.float32), SR)
    return path
