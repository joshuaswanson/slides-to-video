import json
import subprocess

import numpy as np
import pytest

from slides_to_video.audio import build_narration_track
from slides_to_video.script import Slide
from slides_to_video.tools import PipelineError
from slides_to_video.video import (
    assemble_video, extract_slide_images, format_srt_time, images_for_slides, write_srt,
)

from .conftest import make_pdf


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,height",
         "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)


def test_format_srt_time_rounds():
    assert format_srt_time(0) == "00:00:00,000"
    assert format_srt_time(59.9996) == "00:01:00,000"
    assert format_srt_time(3723.0456) == "01:02:03,046"


def test_srt_matches_narration_spans(tmp_path):
    slides = [Slide(1, "One [pause] two"), Slide(2, ""), Slide(3, "Three")]
    clips = [np.zeros(2000, np.float32), np.zeros(0, np.float32), np.zeros(1000, np.float32)]
    track = build_narration_track(clips, 1000, pause=1.0)
    out = tmp_path / "subs.srt"
    write_srt(slides, track, out)
    assert out.read_text() == (
        "1\n00:00:01,000 --> 00:00:03,000\nOne two\n\n"
        "2\n00:00:07,000 --> 00:00:08,000\nThree\n"
    )


def test_extract_caches_by_pdf_contents(tmp_path):
    pdf = make_pdf(tmp_path / "a.pdf", 3)
    out = tmp_path / "images"
    images = extract_slide_images(pdf, out, height=180)
    assert [p.name for p in images] == ["slide-1.png", "slide-2.png", "slide-3.png"]
    assert len(list((out / "thumbs").glob("*.png"))) == 3
    mtime = images[0].stat().st_mtime_ns

    assert extract_slide_images(pdf, out, height=180)[0].stat().st_mtime_ns == mtime

    make_pdf(pdf, 2, shade=0.6)
    assert len(extract_slide_images(pdf, out, height=180)) == 2


def test_extract_rejects_odd_height(tmp_path):
    with pytest.raises(PipelineError):
        extract_slide_images(make_pdf(tmp_path / "a.pdf", 1), tmp_path / "i", height=181)


def test_images_for_slides_reports_missing_pages(tmp_path):
    images = [tmp_path / "slide-1.png"]
    assert images_for_slides([Slide(1, "")], images) == images
    with pytest.raises(PipelineError, match=r"\[2\]"):
        images_for_slides([Slide(1, ""), Slide(2, "")], images)


def test_assemble_video_duration_and_size(tmp_path):
    images = extract_slide_images(make_pdf(tmp_path / "a.pdf", 2), tmp_path / "img", height=180)
    sr = 24000
    track = build_narration_track(
        [np.full(sr, 0.1, np.float32), np.full(sr // 2, 0.1, np.float32)], sr, pause=0.5,
    )
    out = tmp_path / "out.mp4"
    assemble_video(images, track, out, height=180)
    info = probe(out)
    assert float(info["format"]["duration"]) == pytest.approx(track.duration, abs=0.1)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    assert video["height"] == 180
