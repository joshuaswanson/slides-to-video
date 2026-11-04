import io

import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from slides_to_video.server import EditorState, create_app


@pytest.fixture
def client(tmp_path, fake_engine, script_file, pdf_file):
    state = EditorState(
        script_path=script_file, pdf_path=pdf_file, cache_dir=tmp_path / "cache",
        engine_name="fake", height=180,
    )
    with TestClient(create_app(state)) as c:
        c.editor = state
        yield c


def upload_voice(client, voice_wav):
    with open(voice_wav, "rb") as f:
        r = client.post("/api/upload-voice", files={"file": ("me.wav", f, "audio/wav")})
    assert r.status_code == 200, r.text


def ready(client, voice_wav):
    assert client.post("/api/load-engine", json={"engine": "fake", "device": "cpu"}).status_code == 200
    upload_voice(client, voice_wav)


def test_fresh_cache_dir_lists_slides(tmp_path, fake_engine, script_file):
    state = EditorState(script_path=script_file, pdf_path=None, cache_dir=tmp_path / "nope" / "cache")
    with TestClient(create_app(state)) as c:
        r = c.get("/api/slides")
        assert r.status_code == 200
        assert [s["slide_num"] for s in r.json()] == [1, 2, 3]
        assert c.get("/api/config").json()["has_slides"] is False


def test_slides_rendered_on_startup(client):
    assert client.get("/api/config").json()["has_slides"] is True
    assert client.get("/api/slide-image/1").headers["content-type"] == "image/png"
    assert client.get("/api/slide-thumb/3").status_code == 200
    assert client.get("/api/slide-image/4").status_code == 404


def test_load_engine_uses_requested_device(client):
    r = client.post("/api/load-engine", json={"engine": "fake", "device": "cpu"})
    assert r.status_code == 200
    assert client.editor.engine.device == "cpu"
    assert client.post("/api/load-engine", json={"engine": "nope"}).status_code == 400


def test_settings_validation(client):
    assert client.post("/api/settings", json={"language": "de", "pause": 0.5}).json()["language"] == "de"
    assert client.post("/api/settings", json={"language": "xx"}).status_code == 400
    assert client.post("/api/settings", json={"pause": -1}).status_code == 422
    assert client.post("/api/settings", json={"speed": 0.1}).status_code == 422


def test_generation_requires_engine_and_voice(client, voice_wav):
    r = client.post("/api/generate/1")
    assert r.status_code == 400 and "engine" in r.json()["error"]
    client.post("/api/load-engine", json={"engine": "fake", "device": "cpu"})
    assert "voice" in client.post("/api/generate/1").json()["error"]


def test_generate_edit_and_language_invalidate(client, voice_wav):
    ready(client, voice_wav)
    assert client.post("/api/generate/2").status_code == 200
    slides = {s["slide_num"]: s for s in client.get("/api/slides").json()}
    assert slides[2]["has_audio"] and not slides[1]["has_audio"]

    r = client.post("/api/update-script/2", json={"text": "Brand new words."})
    assert r.status_code == 200
    assert not client.get("/api/slides").json()[1]["has_audio"]
    assert "Brand new words." in client.editor.script_path.read_text()

    client.post("/api/generate/2")
    client.post("/api/settings", json={"language": "fr"})
    assert not client.get("/api/slides").json()[1]["has_audio"]


def test_update_script_rejects_separator(client):
    r = client.post("/api/update-script/1", json={"text": "a\n---\nb"})
    assert r.status_code == 400


def test_preview_audio_timestamps_match_slide_starts(client, voice_wav):
    ready(client, voice_wav)
    assert "[1, 2, 3]" in client.post("/api/build-preview-audio").json()["error"]
    client.post("/api/generate-all")
    client.post("/api/settings", json={"pause": 0.5, "use_click": True})
    data = client.post("/api/build-preview-audio").json()
    times = [t["time"] for t in data["timestamps"]]
    assert times[0] == 0
    durations = [s["duration"] for s in client.get("/api/slides").json()]
    assert times[1] == pytest.approx(durations[0] + 1.0, abs=0.06)

    audio, sr = sf.read(io.BytesIO(client.get("/api/preview-audio").content))
    assert len(audio) / sr == pytest.approx(data["total_duration"], abs=0.06)


def test_build_video(client, voice_wav):
    ready(client, voice_wav)
    assert client.post("/api/build-video").json()["status"] == "ok"
    assert client.get("/api/video").headers["content-type"] == "video/mp4"


def test_upload_slides_rerenders(client, tmp_path):
    from .conftest import make_pdf
    pdf = make_pdf(tmp_path / "new.pdf", 5)
    with open(pdf, "rb") as f:
        r = client.post("/api/upload-slides", files={"file": ("new.pdf", f, "application/pdf")})
    assert r.json()["message"] == "Loaded 5 slides."
    assert client.get("/api/slide-image/5").status_code == 200


def test_no_engine_selected_hides_audio_and_blocks_generation(tmp_path, fake_engine, script_file, voice_wav):
    state = EditorState(script_path=script_file, pdf_path=None, cache_dir=tmp_path / "cache")
    with TestClient(create_app(state)) as c:
        assert c.get("/api/config").json()["engine"] is None
        upload_voice(c, voice_wav)
        assert not any(s["has_audio"] for s in c.get("/api/slides").json())
        for path in ["/api/generate/1", "/api/generate-all", "/api/build-preview-audio"]:
            r = c.post(path)
            assert r.status_code == 400 and "Select a TTS engine" in r.json()["error"]

        assert c.post("/api/settings", json={"engine": "fake"}).json()["engine"] == "fake"
        assert "Load a TTS engine" in c.post("/api/generate/1").json()["error"]


def test_selecting_another_engine_unloads_and_hides_its_clips(client, voice_wav, monkeypatch):
    from slides_to_video import tts_engines
    from .conftest import FakeEngine

    class OtherEngine(FakeEngine):
        name = "other"

    monkeypatch.setitem(tts_engines.ENGINES, "other", OtherEngine)
    ready(client, voice_wav)
    client.post("/api/generate/1")
    assert client.get("/api/slides").json()[0]["has_audio"]

    config = client.post("/api/settings", json={"engine": "other"}).json()
    assert config["engine"] == "other" and not config["engine_loaded"]
    assert not client.get("/api/slides").json()[0]["has_audio"]
    assert client.post("/api/settings", json={"engine": "nope"}).status_code == 400

    client.post("/api/settings", json={"engine": "fake"})
    assert client.get("/api/slides").json()[0]["has_audio"]
