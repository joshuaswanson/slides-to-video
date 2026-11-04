import hashlib
import json

import numpy as np
import pytest
import soundfile as sf

from slides_to_video.audio import (
    ClipCache, build_narration_track, ensure_clips, load_audio, make_ambient_loop,
    prepare_voice, synthesize_slide,
)
from slides_to_video.script import Slide

from .conftest import SR, FakeEngine


def test_track_layout_and_click_position():
    clips = [np.full(100, 0.1, np.float32), np.full(50, 0.2, np.float32)]
    click = np.zeros(20, np.float32)
    click[10] = 0.5
    track = build_narration_track(clips, 1000, pause=0.03, click=click, click_split=0.01)

    assert len(track.samples) == (30 + 100 + 30) * 2 - 50
    assert track.slide_starts == [0.0, 0.16]
    assert track.narration_spans == [(0.03, 0.13), (0.19, 0.24)]
    assert track.slide_durations() == pytest.approx([0.16, 0.11])
    assert track.samples[160] == pytest.approx(0.5)
    assert np.count_nonzero(track.samples[:30]) == 0


def test_track_fills_pauses_with_ambient_loop():
    ambient = np.array([0.01, 0.02, 0.03], np.float32)
    track = build_narration_track([np.zeros(2, np.float32)], 1000, pause=0.005, ambient=ambient)
    assert track.samples.tolist() == pytest.approx([0.01, 0.02, 0.03, 0.01, 0.02, 0, 0, 0.01, 0.02, 0.03, 0.01, 0.02])


def test_track_without_click_on_single_slide():
    track = build_narration_track([np.ones(10, np.float32)], 100, pause=0.1, click=np.ones(5, np.float32))
    assert track.samples.sum() == pytest.approx(10)


def test_ambient_loop_stops_before_speech_and_tiles_smoothly():
    loop, sr = make_ambient_loop(FakeEngine(), None, "en")
    assert sr == SR
    assert len(loop) < SR
    assert np.abs(loop).max() < 0.01
    seam = abs(float(loop[-1]) - float(loop[0]))
    typical_step = np.abs(np.diff(loop)).max()
    assert seam <= typical_step * 1.5


def test_synthesize_inserts_pauses_including_leading(tmp_path):
    engine = FakeEngine()
    wav, sr = synthesize_slide(Slide(1, "[pause 0.5] one two [pause] three"), engine, tmp_path, "en")
    assert sr == SR
    assert len(wav) == int(0.5 * SR) + 2 * int(0.1 * SR) + int(0.5 * SR) + int(0.1 * SR)
    assert engine.calls == ["one two", "three"]


def test_synthesize_empty_slide_makes_empty_clip(tmp_path):
    engine = FakeEngine()
    wav, _ = synthesize_slide(Slide(1, ""), engine, tmp_path, "en")
    assert len(wav) == 0 and engine.calls == []


def test_clip_cache_tracks_text_and_settings(tmp_path, voice_wav):
    slide = Slide(1, "Hello world")
    cache = ClipCache(tmp_path / "clips", "fake", "en", voice_wav)
    assert not cache.is_fresh(slide)
    cache.store(slide, np.zeros(10, np.float32), SR)
    assert cache.is_fresh(slide)
    assert not cache.is_fresh(Slide(1, "Hello there"))
    assert not ClipCache(tmp_path / "clips", "fake", "de", voice_wav).is_fresh(slide)
    assert not ClipCache(tmp_path / "clips", "other", "en", voice_wav).is_fresh(slide)

    other_voice = tmp_path / "other.wav"
    sf.write(str(other_voice), np.ones(100, np.float32) * 0.1, SR)
    assert not ClipCache(tmp_path / "clips", "fake", "en", other_voice).is_fresh(slide)


def test_clip_cache_adopts_legacy_manifest(tmp_path, voice_wav, capsys):
    clips = tmp_path / "clips"
    clips.mkdir()
    slide = Slide(2, "Old take")
    sf.write(str(clips / "slide_02.wav"), np.zeros(10, np.float32), SR)
    legacy = hashlib.sha256(slide.narration.encode()).hexdigest()[:16]
    (clips / "hashes.json").write_text(json.dumps({"slide_02": legacy}))

    assert ClipCache(clips, "fake", "en", None).is_fresh(slide)
    assert json.loads((clips / "hashes.json").read_text())["slide_02"] == legacy

    assert "WARNING" not in capsys.readouterr().out
    cache = ClipCache(clips, "fake", "en", voice_wav)
    assert cache.is_fresh(slide)
    assert "slide 2" in capsys.readouterr().out
    assert json.loads((clips / "hashes.json").read_text())["slide_02"] != legacy
    assert cache.is_fresh(slide)
    assert "WARNING" not in capsys.readouterr().out
    assert not ClipCache(clips, "fake", "de", voice_wav).is_fresh(slide)


def test_ensure_clips_generates_only_stale(tmp_path, voice_wav):
    engine = FakeEngine()
    cache = ClipCache(tmp_path / "clips", "fake", "en", voice_wav)
    slides = [Slide(1, "a b"), Slide(2, "c")]
    ensure_clips(slides, engine, voice_wav, cache, "en", log=lambda _: None)
    assert engine.calls == ["a b", "c"]
    ensure_clips([Slide(1, "a b"), Slide(2, "changed")], engine, voice_wav, cache, "en", log=lambda _: None)
    assert engine.calls == ["a b", "c", "changed"]


def test_load_audio_resamples_and_stretches(voice_wav):
    assert len(load_audio(voice_wav, SR)) == SR
    assert len(load_audio(voice_wav, 16000)) == pytest.approx(16000, abs=50)
    assert len(load_audio(voice_wav, SR, speed=2.0)) == pytest.approx(SR / 2, rel=0.02)


def test_prepare_voice_concatenates(tmp_path, voice_wav):
    out = prepare_voice([voice_wav, voice_wav], tmp_path / "voice.wav")
    info = sf.info(str(out))
    assert info.channels == 1 and info.frames == 2 * SR
