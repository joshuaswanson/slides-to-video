import json
import subprocess

import pytest

from slides_to_video import cli


@pytest.fixture
def run_cli(monkeypatch, fake_engine, tmp_path):
    def run(*args):
        cli.main([*args, "--tts-engine", "fake", "--device", "cpu", "--cache-dir", str(tmp_path / "cache")])
    return run


def test_cli_builds_video_and_srt(run_cli, tmp_path, script_file, pdf_file, voice_wav):
    out, srt = tmp_path / "out.mp4", tmp_path / "out.srt"
    run_cli(
        "--slides", str(pdf_file), "--script", str(script_file), "--voice", str(voice_wav),
        "--output", str(out), "--srt", str(srt), "--click-sound", "--speed", "1.25",
        "--pause", "0.4", "--height", "180",
    )
    duration = float(json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(out)],
        capture_output=True, text=True, check=True,
    ).stdout)["format"]["duration"])
    words = 3 + 11 + 1
    expected = 0.1 * words / 1.25 + 0.2 / 1.25 + 3 * 2 * 0.4
    assert duration == pytest.approx(expected, abs=0.15)
    assert srt.read_text().count("-->") == 3
    assert "[pause" not in srt.read_text()


def test_cli_preview_and_only_slides(run_cli, tmp_path, script_file, pdf_file, voice_wav, capsys):
    run_cli(
        "--slides", str(pdf_file), "--script", str(script_file), "--voice", str(voice_wav),
        "--preview", "--only-slides", "2-3",
    )
    output = capsys.readouterr().out
    assert "slide_02.wav" in output and "slide_01.wav" not in output


def test_cli_reports_missing_pages(run_cli, tmp_path, script_file, voice_wav):
    from .conftest import make_pdf
    pdf = make_pdf(tmp_path / "short.pdf", 2)
    with pytest.raises(SystemExit, match="PDF has 2 pages"):
        run_cli("--slides", str(pdf), "--script", str(script_file), "--voice", str(voice_wav))


def test_cli_rejects_unsupported_language(monkeypatch, tmp_path, script_file, pdf_file, voice_wav):
    with pytest.raises(SystemExit, match="does not support"):
        cli.main([
            "--slides", str(pdf_file), "--script", str(script_file), "--voice", str(voice_wav),
            "--tts-engine", "chatterbox", "--language", "de", "--cache-dir", str(tmp_path / "c"),
        ])


def test_cli_requires_engine(tmp_path, script_file, pdf_file, voice_wav, capsys):
    with pytest.raises(SystemExit) as exit_info:
        cli.main(["--slides", str(pdf_file), "--script", str(script_file), "--voice", str(voice_wav)])
    assert exit_info.value.code == 2
    assert "--tts-engine" in capsys.readouterr().err
