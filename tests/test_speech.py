import numpy as np

from slides_to_video.speech import make_ambient_loop, split_pauses, synthesize

from .conftest import SR, FakeEngine


def test_split_pauses():
    assert split_pauses("[pause] Hi [pause 1.5] there [pause .25]") == [0.5, "Hi", 1.5, "there", 0.25]
    assert split_pauses("No pauses") == ["No pauses"]
    assert split_pauses("") == []


def test_synthesize_inserts_pauses_including_leading(tmp_path):
    engine = FakeEngine()
    wav, sr = synthesize("[pause 0.5] one\ntwo [pause] three", engine, tmp_path, "en")
    assert sr == SR
    assert len(wav) == int(0.5 * SR) + 2 * int(0.1 * SR) + int(0.5 * SR) + int(0.1 * SR)
    assert engine.calls == ["one two", "three"]


def test_synthesize_empty_text_makes_empty_clip(tmp_path):
    engine = FakeEngine()
    wav, _ = synthesize("", engine, tmp_path, "en")
    assert len(wav) == 0 and engine.calls == []


def test_ambient_loop_stops_before_speech_and_tiles_smoothly():
    loop, sr = make_ambient_loop(FakeEngine(), None, "en")
    assert sr == SR
    assert len(loop) < SR
    assert np.abs(loop).max() < 0.01
    seam = abs(float(loop[-1]) - float(loop[0]))
    assert seam <= np.abs(np.diff(loop)).max() * 1.5
