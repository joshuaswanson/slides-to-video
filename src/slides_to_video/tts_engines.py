"""TTS engine abstraction for voice cloning.

Each engine loads a model, then generates audio from text using a voice sample
for cloning.
"""

from __future__ import annotations

import abc
from pathlib import Path

import numpy as np

LANGUAGES = {
    "en": "English", "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
    "fr": "French", "de": "German", "es": "Spanish", "ar": "Arabic",
    "ru": "Russian", "pt": "Portuguese",
}


class TTSEngine(abc.ABC):
    name: str
    languages: frozenset[str] = frozenset(LANGUAGES)

    @abc.abstractmethod
    def load(self, device: str) -> None:
        """Load the model onto the given device."""

    @abc.abstractmethod
    def generate(
        self, text: str, voice_wav_path: Path, language: str = "en",
    ) -> tuple[np.ndarray, int]:
        """Return (mono float32 waveform, sample_rate) in the cloned voice."""


class ChatterboxEngine(TTSEngine):
    """Chatterbox TTS: local zero-shot voice cloning, English only."""

    name = "chatterbox"
    languages = frozenset({"en"})

    def __init__(self) -> None:
        self.model = None

    def load(self, device: str) -> None:
        from chatterbox.tts import ChatterboxTTS
        self.model = ChatterboxTTS.from_pretrained(device)

    def generate(
        self, text: str, voice_wav_path: Path, language: str = "en",
    ) -> tuple[np.ndarray, int]:
        wav_tensor = self.model.generate(text, audio_prompt_path=str(voice_wav_path))
        wav = wav_tensor.squeeze().cpu().numpy().astype(np.float32)
        return wav, self.model.sr


class Qwen3TTSEngine(TTSEngine):
    """Qwen3-TTS: voice cloning from a few seconds of audio, 10 languages."""

    name = "qwen3"

    def __init__(self) -> None:
        self.model = None

    def load(self, device: str) -> None:
        import torch
        from qwen_tts import Qwen3TTSModel
        self.model = Qwen3TTSModel.from_pretrained(
            "Qwen/Qwen3-TTS-12Hz-1.7B-Base",
            device_map=device,
            dtype=torch.bfloat16,
        )

    def generate(
        self, text: str, voice_wav_path: Path, language: str = "en",
    ) -> tuple[np.ndarray, int]:
        wavs, sr = self.model.generate_voice_clone(
            text=text,
            language=LANGUAGES[language],
            ref_audio=str(voice_wav_path),
            x_vector_only_mode=True,
        )
        return np.asarray(wavs[0], dtype=np.float32), sr


ENGINES: dict[str, type[TTSEngine]] = {
    "chatterbox": ChatterboxEngine,
    "qwen3": Qwen3TTSEngine,
}


def get_engine(name: str) -> TTSEngine:
    if name not in ENGINES:
        available = ", ".join(sorted(ENGINES))
        raise ValueError(f"Unknown TTS engine {name!r}. Available: {available}")
    return ENGINES[name]()


def check_language(engine_name: str, language: str) -> None:
    supported = ENGINES[engine_name].languages
    if language not in supported:
        raise ValueError(
            f"Engine {engine_name!r} does not support language {language!r}. "
            f"Supported: {', '.join(sorted(supported))}"
        )
