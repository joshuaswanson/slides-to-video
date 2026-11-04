"""Generate a narrated presentation video from slides, a script, and a voice sample.

Usage:
    uv run slides-to-video --slides presentation.pdf --script script.md --voice voice.m4a
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import soundfile as sf

from .audio import (
    DEFAULT_CLICK, MAX_SPEED, MIN_SPEED, ClipCache, ambient_loop, assemble_track,
    ensure_clips, prepare_voice,
)
from .script import ScriptError, parse_script, parse_slide_range
from .tools import PipelineError
from .tts_engines import ENGINES, LANGUAGES, check_language, get_engine
from .video import DEFAULT_HEIGHT, assemble_video, extract_slide_images, images_for_slides, write_srt


def _speed(value: str) -> float:
    speed = float(value)
    if not MIN_SPEED <= speed <= MAX_SPEED:
        raise argparse.ArgumentTypeError(f"must be between {MIN_SPEED} and {MAX_SPEED}")
    return speed


def _non_negative(value: str) -> float:
    number = float(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return number


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--slides", type=Path, required=True, help="Path to slides PDF")
    parser.add_argument("--script", type=Path, required=True, help="Path to narration script (markdown)")
    parser.add_argument(
        "--voice", type=Path, required=True, nargs="+",
        help="Voice sample(s) to clone. Multiple files are concatenated.",
    )
    parser.add_argument("--output", type=Path, default=Path("output.mp4"), help="Output video path")
    parser.add_argument(
        "--pause", type=_non_negative, default=1.0,
        help="Seconds of ambient pause before and after each slide's narration (default: 1.0)",
    )
    parser.add_argument("--device", default="cuda", help="PyTorch device for the TTS model")
    parser.add_argument(
        "--tts-engine", required=True, choices=sorted(ENGINES),
        help="TTS engine for voice cloning. Cached clips are tied to the engine that made them.",
    )
    parser.add_argument(
        "--language", default="en", choices=sorted(LANGUAGES), help="Narration language (default: en)",
    )
    parser.add_argument(
        "--speed", type=_speed, default=None,
        help="Narration speed multiplier, e.g. 1.2 for 20%% faster",
    )
    parser.add_argument(
        "--only-slides", default=None, metavar="RANGE",
        help="Only process specific slides, e.g. '3-7' or '1,3,5-7'",
    )
    parser.add_argument(
        "--preview", action="store_true", help="Generate audio only and skip video assembly",
    )
    parser.add_argument("--srt", type=Path, default=None, metavar="PATH", help="Export SRT subtitles")
    parser.add_argument(
        "--click-sound", type=Path, nargs="?", const=DEFAULT_CLICK, default=None, metavar="PATH",
        help="Play a click at each slide transition. Without PATH, uses the bundled click.",
    )
    parser.add_argument(
        "--height", type=int, default=DEFAULT_HEIGHT, help=f"Video height in pixels (default: {DEFAULT_HEIGHT})",
    )
    parser.add_argument(
        "--cache-dir", type=Path, default=Path(".cache"), help="Directory for intermediate files",
    )
    parser.add_argument("--regenerate", action="store_true", help="Regenerate all audio clips")
    parser.add_argument(
        "--regenerate-slide", type=int, nargs="+", default=[], metavar="N",
        help="Regenerate audio for specific slide(s), e.g. --regenerate-slide 3 7",
    )
    return parser


def run(args: argparse.Namespace) -> None:
    check_language(args.tts_engine, args.language)
    audio_dir = args.cache_dir / "audio_clips"

    print("Parsing script...")
    slides = parse_script(args.script.read_text())
    if args.only_slides:
        requested = parse_slide_range(args.only_slides)
        slides = [s for s in slides if s.num in requested]
    if not slides:
        raise PipelineError("No slides to process")
    print(f"  {len(slides)} slides: {[s.num for s in slides]}\n")

    if not args.preview:
        print("Extracting slide images...")
        images = images_for_slides(
            slides, extract_slide_images(args.slides, args.cache_dir / "slide_images", args.height),
        )
        print()

    print("Preparing voice sample...")
    voice = prepare_voice(args.voice, args.cache_dir / "voice.wav")
    cache = ClipCache(audio_dir, args.tts_engine, args.language, voice)
    if args.regenerate:
        shutil.rmtree(audio_dir, ignore_errors=True)
    for num in args.regenerate_slide:
        cache.invalidate(num)
    print()

    print(f"Loading TTS engine ({args.tts_engine})...")
    engine = get_engine(args.tts_engine)
    engine.load(args.device)
    print()

    print("Generating audio clips...")
    clips = ensure_clips(slides, engine, voice, cache, args.language)
    print()

    if args.preview:
        print("Preview mode: skipping video assembly.")
        for clip in clips:
            print(f"  {clip.name}: {sf.info(str(clip)).duration:.1f}s")
        return

    print("Assembling narration...")
    track = assemble_track(
        clips, pause=args.pause, speed=args.speed, click_path=args.click_sound,
        ambient_path=ambient_loop(cache, engine, voice, args.language),
    )
    if args.srt:
        write_srt(slides, track, args.srt)
        print(f"  Saved subtitles to {args.srt}")

    print("Encoding video...")
    assemble_video(images, track, args.output, args.height)
    print(f"\nDone. {track.duration:.1f}s ({track.duration / 60:.1f} min) saved to {args.output}")


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        run(args)
    except (PipelineError, ScriptError, ValueError, FileNotFoundError) as e:
        sys.exit(f"Error: {e}")


if __name__ == "__main__":
    main()
