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


def make_pdf(path: Path, pages: int, shade: float = 0.2) -> Path:
    """Write a minimal PDF with 16:9 pages, each filled with a different gray."""
    objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [{}] /Count {} >>".format(
            " ".join(f"{3 + 2 * i} 0 R" for i in range(pages)), pages,
        ),
    ]
    for i in range(pages):
        gray = (shade + 0.15 * i) % 1
        stream = f"{gray:.2f} g 0 0 320 180 re f"
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 180] /Contents {4 + 2 * i} 0 R >>"
        )
        objects.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
    out = b"%PDF-1.4\n"
    offsets = []
    for num, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{num} 0 obj\n{body}\nendobj\n".encode()
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    path.write_bytes(out)
    return path


SCRIPT = """# Test talk

---

## Slide 1 - Title

Hello there everyone.

---

## Slide 2 - Middle

First paragraph line one
continues here.

Second paragraph [pause 0.2] after a pause.

---

## Slide 3 - End

Goodbye.
"""


@pytest.fixture
def script_file(tmp_path) -> Path:
    path = tmp_path / "script.md"
    path.write_text(SCRIPT)
    return path


@pytest.fixture
def pdf_file(tmp_path) -> Path:
    return make_pdf(tmp_path / "slides.pdf", 3)
