"""Narration audio: voice preparation, per-slide TTS clips, and the full track."""

from __future__ import annotations

import hashlib
import json
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf

from .script import Slide, split_pauses
from .tools import PipelineError, atomic_write_text, file_hash, run_tool, text_hash
from .tts_engines import TTSEngine

VOICE_SAMPLE_RATE = 24000
DEFAULT_CLICK = Path(__file__).parent / "assets" / "click.wav"
# The bundled click is a key press (peak at 45 ms) and release (peak at 120 ms).
# The slide image changes at this offset, between the two.
CLICK_SPLIT = 0.085
MIN_SPEED, MAX_SPEED = 0.5, 100.0
AMBIENT_RMS_THRESHOLD = 0.01
_MANIFEST_LOCK = threading.Lock()


def load_audio(path: Path, sample_rate: int, speed: float | None = None) -> np.ndarray:
    """Decode any audio file to mono float32 at sample_rate, optionally time-stretched."""
    stretch = speed is not None and speed != 1.0
    if stretch and not MIN_SPEED <= speed <= MAX_SPEED:
        raise PipelineError(f"Speed must be between {MIN_SPEED} and {MAX_SPEED}, got {speed}")
    if path.suffix.lower() == ".wav":
        info = sf.info(str(path))
        if info.frames == 0:
            return np.zeros(0, dtype=np.float32)
        if info.samplerate == sample_rate and info.channels == 1 and not stretch:
            return sf.read(str(path), dtype="float32")[0]
    cmd = ["ffmpeg", "-v", "error", "-i", str(path)]
    if stretch:
        cmd += ["-filter:a", f"atempo={speed}"]
    cmd += ["-ac", "1", "-ar", str(sample_rate), "-f", "f32le", "-"]
    return np.frombuffer(run_tool(cmd, stdout_bytes=True), dtype=np.float32).copy()


def prepare_voice(voice_paths: list[Path], output_path: Path) -> Path:
    """Convert one or more voice samples into a single mono WAV for cloning."""
    for path in voice_paths:
        if not path.exists():
            raise PipelineError(f"Voice sample not found: {path}")
    samples = [load_audio(p, VOICE_SAMPLE_RATE) for p in voice_paths]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(output_path), np.concatenate(samples), VOICE_SAMPLE_RATE)
    return output_path


def clip_path(directory: Path, slide_num: int) -> Path:
    return directory / f"slide_{slide_num:02d}.wav"


class ClipCache:
    """Per-slide narration clips, valid for one (engine, language, voice) combination."""

    def __init__(
        self, directory: Path, engine_name: str, language: str, voice_path: Path | None,
    ) -> None:
        self.directory = directory
        self.engine_name, self.language = engine_name, language
        self.has_voice = voice_path is not None and voice_path.exists()
        voice = file_hash(voice_path) if self.has_voice else ""
        self.settings_key = text_hash(engine_name, language, voice)
        self.manifest_path = directory / "hashes.json"

    def path(self, slide_num: int) -> Path:
        return clip_path(self.directory, slide_num)

    @property
    def ambient_path(self) -> Path:
        return self.directory / f"ambient_{self.settings_key}.wav"

    def _manifest(self) -> dict[str, str]:
        if self.manifest_path.exists():
            return json.loads(self.manifest_path.read_text())
        return {}

    def _key(self, slide: Slide) -> str:
        return text_hash(self.settings_key, slide.narration)

    def is_fresh(self, slide: Slide) -> bool:
        path = self.path(slide.num)
        if not path.exists():
            return False
        entry = self._manifest().get(path.stem)
        if entry == self._key(slide):
            return True
        # Manifests written before version 0.2 hash only the text. Those clips
        # are adopted for the first voice they are used with.
        if entry == hashlib.sha256(slide.narration.encode()).hexdigest()[:16]:
            if self.has_voice:
                self._set_entry(path.stem, self._key(slide))
                print(
                    f"  WARNING: slide {slide.num} uses a clip cached before version 0.2. "
                    f"It is now assigned to engine {self.engine_name!r}, language "
                    f"{self.language!r} and the current voice sample. If it was recorded "
                    "with a different engine or voice, regenerate it."
                )
            return True
        return False

    def _set_entry(self, stem: str, key: str) -> None:
        with _MANIFEST_LOCK:
            manifest = self._manifest()
            manifest[stem] = key
            atomic_write_text(self.manifest_path, json.dumps(manifest, indent=2, sort_keys=True))

    def store(self, slide: Slide, wav: np.ndarray, sample_rate: int) -> Path:
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self.path(slide.num)
        sf.write(str(path), wav, sample_rate)
        self._set_entry(path.stem, self._key(slide))
        return path

    def invalidate(self, slide_num: int) -> None:
        self.path(slide_num).unlink(missing_ok=True)


def synthesize_slide(
    slide: Slide, engine: TTSEngine, voice_path: Path, language: str,
) -> tuple[np.ndarray, int]:
    """Generate one slide's narration, inserting silence for [pause] markers."""
    items = split_pauses(slide.narration)
    speech = {
        i: engine.generate(item, voice_path, language=language)
        for i, item in enumerate(items) if isinstance(item, str)
    }
    rates = {sr for _, sr in speech.values()}
    if len(rates) > 1:
        raise PipelineError(f"Engine returned mixed sample rates {sorted(rates)}")
    sample_rate = rates.pop() if rates else VOICE_SAMPLE_RATE
    pieces = [
        speech[i][0] if i in speech else np.zeros(round(item * sample_rate), dtype=np.float32)
        for i, item in enumerate(items)
    ]
    wav = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)
    return wav.astype(np.float32), sample_rate


def ensure_clips(
    slides: list[Slide],
    engine: TTSEngine,
    voice_path: Path,
    cache: ClipCache,
    language: str,
    log=print,
) -> list[Path]:
    """Return one clip per slide, generating only those missing or out of date."""
    paths = []
    for slide in slides:
        if cache.is_fresh(slide):
            log(f"  Slide {slide.num}: using cached audio")
        else:
            log(f"  Slide {slide.num}: generating...")
            wav, sr = synthesize_slide(slide, engine, voice_path, language)
            cache.store(slide, wav, sr)
            log(f"  Slide {slide.num}: {len(wav) / sr:.1f}s")
        paths.append(cache.path(slide.num))
    return paths


def make_ambient_loop(
    engine: TTSEngine, voice_path: Path, language: str,
) -> tuple[np.ndarray, int]:
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


def ambient_loop(
    cache: ClipCache, engine: TTSEngine | None, voice_path: Path | None, language: str,
) -> Path | None:
    """Return the cached ambient loop, creating it if an engine is available."""
    if cache.ambient_path.exists():
        return cache.ambient_path
    if engine is None or voice_path is None:
        return None
    loop, sr = make_ambient_loop(engine, voice_path, language)
    cache.directory.mkdir(parents=True, exist_ok=True)
    sf.write(str(cache.ambient_path), loop, sr)
    return cache.ambient_path


@dataclass
class NarrationTrack:
    samples: np.ndarray
    sample_rate: int
    slide_starts: list[float]
    narration_spans: list[tuple[float, float]]

    @property
    def duration(self) -> float:
        return len(self.samples) / self.sample_rate

    def slide_durations(self) -> list[float]:
        ends = self.slide_starts[1:] + [self.duration]
        return [end - start for start, end in zip(self.slide_starts, ends)]

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(path), self.samples, self.sample_rate, subtype="PCM_16")


def _tile(loop: np.ndarray | None, n: int) -> np.ndarray:
    if loop is None or len(loop) == 0:
        return np.zeros(n, dtype=np.float32)
    return np.tile(loop, -(-n // len(loop)))[:n]


def build_narration_track(
    clips: list[np.ndarray],
    sample_rate: int,
    pause: float,
    ambient: np.ndarray | None = None,
    click: np.ndarray | None = None,
    click_split: float = CLICK_SPLIT,
) -> NarrationTrack:
    """Lay out each slide as [pause][narration][pause] and add transition clicks.

    Pauses are filled with the ambient loop. The click is placed so that
    click_split seconds into it lands exactly on the slide boundary.
    """
    if pause < 0:
        raise PipelineError("Pause must not be negative")
    gap = _tile(ambient, round(pause * sample_rate))
    pieces, starts, spans = [], [], []
    pos = 0
    for clip in clips:
        starts.append(pos)
        narration_start = pos + len(gap)
        spans.append((narration_start, narration_start + len(clip)))
        pieces += [gap, clip.astype(np.float32), gap]
        pos = narration_start + len(clip) + len(gap)
    samples = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)

    if click is not None and len(click):
        split = round(click_split * sample_rate)
        for boundary in starts[1:]:
            at = boundary - split
            lo, hi = max(at, 0), min(at + len(click), len(samples))
            samples[lo:hi] += click[lo - at:hi - at]
    np.clip(samples, -1.0, 1.0, out=samples)

    sr = sample_rate
    return NarrationTrack(
        samples=samples,
        sample_rate=sr,
        slide_starts=[s / sr for s in starts],
        narration_spans=[(a / sr, b / sr) for a, b in spans],
    )


def assemble_track(
    clip_paths: list[Path],
    pause: float,
    speed: float | None = None,
    click_path: Path | None = None,
    ambient_path: Path | None = None,
) -> NarrationTrack:
    """Load cached clips at a common sample rate and build the narration track."""
    if not clip_paths:
        raise PipelineError("No slides to assemble")
    sample_rate = sf.info(str(clip_paths[0])).samplerate
    clips = [load_audio(p, sample_rate, speed) for p in clip_paths]
    click = load_audio(click_path, sample_rate) if click_path else None
    ambient = load_audio(ambient_path, sample_rate) if ambient_path else None
    return build_narration_track(clips, sample_rate, pause, ambient=ambient, click=click)
