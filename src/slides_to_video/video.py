"""Slide rendering, video assembly, and subtitles."""

from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

from .audio import NarrationTrack
from .script import Slide, strip_pauses
from .tools import PipelineError, atomic_write_text, file_hash, run_tool

DEFAULT_HEIGHT = 1080
THUMB_HEIGHT = 180
FPS = 30


def _render_pages(pdf_path: Path, out_dir: Path, height: int) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("slide-*.png"):
        old.unlink()
    run_tool([
        "pdftoppm", "-png", "-scale-to-x", "-1", "-scale-to-y", str(height),
        str(pdf_path), str(out_dir / "slide"),
    ])
    return slide_image_paths(out_dir)


def slide_image_paths(directory: Path) -> list[Path]:
    """PNG pages in page order. pdftoppm zero-pads to the page count's width."""
    pages = directory.glob("slide-*.png") if directory.exists() else []
    return sorted(pages, key=lambda p: int(re.search(r"(\d+)$", p.stem).group(1)))


def extract_slide_images(pdf_path: Path, out_dir: Path, height: int = DEFAULT_HEIGHT) -> list[Path]:
    """Render PDF pages to PNG at the given height, plus thumbnails.

    Re-renders only when the PDF contents or the height change.
    """
    if not pdf_path.exists():
        raise PipelineError(f"Slides PDF not found: {pdf_path}")
    if height <= 0 or height % 2:
        raise PipelineError(f"Video height must be a positive even number, got {height}")
    source = {"pdf": file_hash(pdf_path), "height": height}
    manifest = out_dir / "source.json"
    images = slide_image_paths(out_dir)
    if images and manifest.exists() and json.loads(manifest.read_text()) == source:
        return images
    images = _render_pages(pdf_path, out_dir, height)
    _render_pages(pdf_path, out_dir / "thumbs", THUMB_HEIGHT)
    atomic_write_text(manifest, json.dumps(source))
    return images


def images_for_slides(slides: list[Slide], images: list[Path]) -> list[Path]:
    missing = [s.num for s in slides if not 1 <= s.num <= len(images)]
    if missing:
        raise PipelineError(
            f"Script refers to slide(s) {missing}, but the PDF has {len(images)} pages"
        )
    return [images[s.num - 1] for s in slides]


def _concat_quote(path: Path) -> str:
    return "'" + str(path.resolve()).replace("'", "'\\''") + "'"


def assemble_video(
    images: list[Path], track: NarrationTrack, output_path: Path, height: int = DEFAULT_HEIGHT,
) -> None:
    """Show each image for its slide's span of the track and encode in one pass."""
    if len(images) != len(track.slide_starts):
        raise PipelineError("Number of images and slides in the narration track differ")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        audio_path = tmp / "narration.wav"
        track.write(audio_path)
        lines = ["ffconcat version 1.0"]
        for image, duration in zip(images, track.slide_durations()):
            lines += [f"file {_concat_quote(image)}", f"duration {duration:.6f}"]
        # The concat demuxer ignores the last duration unless the file repeats.
        lines.append(f"file {_concat_quote(images[-1])}")
        concat = tmp / "slides.ffconcat"
        concat.write_text("\n".join(lines) + "\n")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        run_tool([
            "ffmpeg", "-y", "-v", "error",
            "-f", "concat", "-safe", "0", "-i", str(concat),
            "-i", str(audio_path),
            "-map", "0:v", "-map", "1:a",
            "-vf", f"scale=-2:{height}:flags=lanczos,format=yuv420p",
            "-r", str(FPS),
            "-c:v", "libx264", "-tune", "stillimage",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            "-shortest",
            str(output_path),
        ])


def format_srt_time(seconds: float) -> str:
    total_ms = round(seconds * 1000)
    h, rem = divmod(total_ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write_srt(slides: list[Slide], track: NarrationTrack, output_path: Path) -> None:
    entries = []
    for slide, (start, end) in zip(slides, track.narration_spans):
        text = strip_pauses(slide.narration)
        if text and end > start:
            entries.append(
                f"{len(entries) + 1}\n{format_srt_time(start)} --> {format_srt_time(end)}\n{text}\n"
            )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(entries))
