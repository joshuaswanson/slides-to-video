"""Generate a narrated presentation video from slides, a script, and a voice sample.

Usage:
    uv run src/generate.py --slides presentation.pdf --script script.md --voice voice.m4a

Requires:
    - A GPU with CUDA support (for TTS voice cloning)
    - ffmpeg and pdftoppm installed

The script should be a markdown file with slide sections separated by '---':

    ## Slide 1 - Title
    Text to narrate for slide 1.

    ---

    ## Slide 2 - Introduction
    Text to narrate for slide 2.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

from tts_engines import TTSEngine, get_engine, ENGINES


def parse_script(script_path: Path) -> list[tuple[int, str]]:
    """Parse the markdown script into (slide_number, text) pairs."""
    content = script_path.read_text()
    slides = []
    for block in re.split(r"^---\s*$", content, flags=re.MULTILINE):
        heading_match = re.search(r"##\s+Slide\s+(\d+)", block)
        if not heading_match:
            continue
        slide_num = int(heading_match.group(1))
        lines = block.strip().split("\n")
        text_lines = [
            line for line in lines if not re.match(r"^#", line) and line.strip()
        ]
        text = " ".join(text_lines).strip()
        if text:
            slides.append((slide_num, text))
    return slides


def parse_slide_range(spec: str) -> set[int]:
    """Parse a slide range specification like '1,3,5-7' into a set of ints."""
    result = set()
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            start, end = part.split("-", 1)
            result.update(range(int(start), int(end) + 1))
        else:
            result.add(int(part))
    return result


def convert_voice_sample(voice_path: Path, output_path: Path) -> Path:
    """Convert voice sample to WAV if needed."""
    if voice_path.suffix == ".wav":
        return voice_path
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(voice_path), "-ar", "24000", "-ac", "1",
         str(output_path)],
        check=True, capture_output=True,
    )
    return output_path


def merge_voice_samples(voice_paths: list[Path], output_path: Path) -> Path:
    """Concatenate multiple voice samples into one WAV file for better cloning."""
    if len(voice_paths) == 1:
        return convert_voice_sample(voice_paths[0], output_path)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        converted = []
        for i, vp in enumerate(voice_paths):
            conv = tmpdir / f"voice_{i:02d}.wav"
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(vp), "-ar", "24000", "-ac", "1",
                 str(conv)],
                check=True, capture_output=True,
            )
            converted.append(conv)

        concat_file = tmpdir / "concat.txt"
        concat_file.write_text(
            "\n".join(f"file '{p}'" for p in converted)
        )
        subprocess.run(
            ["ffmpeg", "-y", "-f", "concat", "-safe", "0",
             "-i", str(concat_file), "-c", "copy", str(output_path)],
            check=True, capture_output=True,
        )
    return output_path


def _text_hash(text: str) -> str:
    """Return a short hash of the slide text for cache invalidation."""
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def _load_cache_hashes(cache_file: Path) -> dict[str, str]:
    """Load slide text hashes from the cache manifest."""
    if cache_file.exists():
        return json.loads(cache_file.read_text())
    return {}


def _save_cache_hashes(cache_file: Path, hashes: dict[str, str]) -> None:
    """Save slide text hashes to the cache manifest."""
    cache_file.write_text(json.dumps(hashes, indent=2))


def _generate_slide_audio(
    text: str,
    engine: TTSEngine,
    voice_wav_path: Path,
    output_path: Path,
    language: str,
) -> float:
    """Generate audio for a single slide, handling [pause N] markers.

    Splits text on [pause] or [pause N] markers, generates each segment
    separately, and concatenates them with silence gaps. Appends '...' to the
    final segment to encourage a natural trailing pause from the TTS model.
    Returns total duration in seconds.
    """
    # Split on [pause] or [pause 0.5] markers
    parts = re.split(r"\[pause(?:\s+([\d.]+))?\]", text)
    # parts alternates: text, pause_duration (or None), text, ...

    segments = []
    pause_durations = []
    for i, part in enumerate(parts):
        if i % 2 == 0:
            stripped = part.strip()
            if stripped:
                segments.append(stripped)
        else:
            pause_durations.append(float(part) if part else 0.5)

    # Simple case: no [pause] markers
    if len(segments) <= 1:
        return engine.generate_to_file(
            segments[0] if segments else text,
            voice_wav_path, output_path, language=language,
        )

    # Generate each segment, concat with silence gaps
    with tempfile.TemporaryDirectory() as seg_tmpdir:
        seg_tmpdir = Path(seg_tmpdir)
        concat_parts = []

        for j, segment in enumerate(segments):
            seg_path = seg_tmpdir / f"seg_{j:02d}.wav"
            engine.generate_to_file(
                segment, voice_wav_path, seg_path, language=language,
            )
            concat_parts.append(seg_path)

            if j < len(pause_durations):
                gap_path = seg_tmpdir / f"gap_{j:02d}.wav"
                # Get sample rate from the segment we just generated
                import soundfile as sf_read
                info = sf_read.info(str(seg_path))
                subprocess.run(
                    ["ffmpeg", "-y", "-f", "lavfi",
                     "-t", str(pause_durations[j]),
                     "-i", f"anullsrc=r={info.samplerate}:cl=mono",
                     "-c:a", "pcm_s16le", str(gap_path)],
                    check=True, capture_output=True,
                )
                concat_parts.append(gap_path)

        # Concatenate all parts
        concat_file = seg_tmpdir / "concat.txt"
        concat_file.write_text(
            "\n".join(f"file '{p}'" for p in concat_parts)
        )
        subprocess.run(
            ["ffmpeg", "-y", "-f", "concat", "-safe", "0",
             "-i", str(concat_file), "-c", "copy", str(output_path)],
            check=True, capture_output=True,
        )

    import soundfile as sf_read
    info = sf_read.info(str(output_path))
    return info.duration


def generate_audio_clips(
    slides: list[tuple[int, str]],
    engine: TTSEngine,
    voice_wav_path: Path,
    output_dir: Path,
    language: str = "en",
) -> list[Path]:
    """Generate TTS audio for each slide using the cloned voice."""
    output_dir.mkdir(exist_ok=True)
    cache_file = output_dir / "hashes.json"
    hashes = _load_cache_hashes(cache_file)
    clip_paths = []
    for slide_num, text in slides:
        out_path = output_dir / f"slide_{slide_num:02d}.wav"
        key = f"slide_{slide_num:02d}"
        current_hash = _text_hash(text)

        if out_path.exists() and hashes.get(key) == current_hash:
            print(f"  Slide {slide_num}: using cached audio")
            clip_paths.append(out_path)
            continue

        if out_path.exists():
            print(f"  Slide {slide_num}: script changed, regenerating...")
            out_path.unlink()
        else:
            print(f"  Slide {slide_num}: generating...")

        duration = _generate_slide_audio(
            text, engine, voice_wav_path, out_path, language,
        )
        hashes[key] = current_hash
        _save_cache_hashes(cache_file, hashes)
        print(f"  Slide {slide_num}: {duration:.1f}s")
        clip_paths.append(out_path)
    return clip_paths



def apply_speed(audio_path: Path, speed: float, output_path: Path) -> None:
    """Adjust playback speed of an audio file using ffmpeg atempo filter."""
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(audio_path),
         "-filter:a", f"atempo={speed}",
         "-c:a", "pcm_s16le", str(output_path)],
        check=True, capture_output=True,
    )


def extract_slide_images(pdf_path: Path, output_dir: Path) -> list[Path]:
    """Convert PDF pages to PNG images."""
    output_dir.mkdir(exist_ok=True)
    existing = sorted(output_dir.glob("slide-*.png"))
    if existing:
        print(f"  Using {len(existing)} cached slide images")
        return existing
    subprocess.run(
        ["pdftoppm", "-png", "-r", "300", str(pdf_path), str(output_dir / "slide")],
        check=True, capture_output=True,
    )
    return sorted(output_dir.glob("slide-*.png"))


def get_audio_duration(audio_path: Path) -> float:
    """Get duration of an audio file in seconds via ffprobe."""
    result = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(audio_path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def format_srt_time(seconds: float) -> str:
    """Format seconds as SRT timestamp (HH:MM:SS,mmm)."""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def generate_srt(
    slides: list[tuple[int, str]],
    audio_clips: list[Path],
    output_path: Path,
    pause: float = 1.0,
) -> None:
    """Generate an SRT subtitle file from slides and their audio durations."""
    entries = []
    current_time = 0.0

    for i, ((_, text), audio_clip) in enumerate(zip(slides, audio_clips)):
        start_time = current_time + pause
        duration = get_audio_duration(audio_clip)
        end_time = start_time + duration

        entries.append(
            f"{i + 1}\n"
            f"{format_srt_time(start_time)} --> {format_srt_time(end_time)}\n"
            f"{text}\n"
        )
        current_time = end_time

    output_path.write_text("\n".join(entries))
    print(f"  Saved subtitles to {output_path}")


def _generate_ambient_pause(
    engine: TTSEngine,
    voice_wav_path: Path,
    output_path: Path,
    duration: float,
    language: str = "en",
) -> None:
    """Generate ambient noise for pauses by feeding spaces to the TTS model.

    The model produces its characteristic background noise when given
    whitespace input. We trim to the clean portion and crossfade-loop it.
    """
    import numpy as np
    import soundfile as sf_read

    raw_path = output_path.parent / "ambient_raw.wav"
    engine.generate_to_file(
        "                    ", voice_wav_path, raw_path, language=language,
    )

    # Find the clean portion (before any speech artifacts appear)
    data, sr = sf_read.read(str(raw_path), dtype="float32")
    window_size = int(0.05 * sr)
    trim_end = len(data)
    for start in range(0, len(data) - window_size, window_size):
        window = data[start:start + window_size]
        rms = float(np.sqrt(np.mean(window ** 2)))
        if rms > 0.01:
            trim_end = start
            break

    trim_end = max(trim_end, int(0.1 * sr))
    clean = data[:trim_end]

    # Crossfade loop point so there's no click when tiling
    fade_samples = int(0.02 * sr)
    if len(clean) > fade_samples * 2:
        fade_out = np.linspace(1, 0, fade_samples, dtype=np.float32)
        fade_in = np.linspace(0, 1, fade_samples, dtype=np.float32)
        clean[-fade_samples:] = (
            clean[-fade_samples:] * fade_out + clean[:fade_samples] * fade_in
        )

    # Tile to fill the requested duration
    n_samples = int(duration * sr)
    n_loops = int(np.ceil(n_samples / len(clean)))
    looped = np.tile(clean, n_loops)[:n_samples]

    sf_read.write(str(output_path), looped, sr)


def assemble_video(
    slide_images: list[Path],
    audio_clips: list[Path],
    slides: list[tuple[int, str]],
    output_path: Path,
    engine: TTSEngine,
    voice_wav_path: Path,
    language: str = "en",
    pause: float = 1.0,
    speed: float | None = None,
    click_sound: Path | None = None,
) -> None:
    """Stitch slide images and audio clips into a video.

    Each slide transition is: [click sound] -> [pause with ambient noise] -> [narration]
    The click has a press and release ~75ms apart. The slide image changes between them.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Optionally adjust audio speed
        if speed is not None and speed != 1.0:
            print(f"  Adjusting audio speed: {speed}x")
            sped_clips = []
            for i, clip in enumerate(audio_clips):
                sped = tmpdir / f"speed_{i:02d}.wav"
                apply_speed(clip, speed, sped)
                sped_clips.append(sped)
            audio_clips = sped_clips

        # Generate ambient noise for pauses using the TTS model itself
        ambient_path = tmpdir / "ambient.wav"
        _generate_ambient_pause(
            engine, voice_wav_path, ambient_path, pause, language=language,
        )

        # Split click into press (down) and release (up), ~75ms boundary.
        # Down plays at end of previous slide, up plays at start of new slide.
        click_down_path = None
        click_up_path = None
        if click_sound:
            click_down_path = tmpdir / "click_down.wav"
            click_up_path = tmpdir / "click_up.wav"
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(click_sound),
                 "-t", "0.075", "-ar", "24000", "-ac", "1",
                 "-c:a", "pcm_s16le", str(click_down_path)],
                check=True, capture_output=True,
            )
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(click_sound),
                 "-ss", "0.075", "-ar", "24000", "-ac", "1",
                 "-c:a", "pcm_s16le", str(click_up_path)],
                check=True, capture_output=True,
            )

        segment_paths = []
        total_duration = 0.0

        for i, (audio_clip, (slide_num, _)) in enumerate(zip(audio_clips, slides)):
            slide_img = slide_images[slide_num - 1]

            # Build pre-pause: ambient (matched to this clip) with click_up overlaid
            pre_ambient = ambient_path
            pre_pause = tmpdir / f"pre_{i:02d}.wav"
            if click_up_path and i > 0:
                subprocess.run(
                    ["ffmpeg", "-y",
                     "-i", str(pre_ambient), "-i", str(click_up_path),
                     "-filter_complex",
                     "[1:a]apad=whole_dur=0[click];"
                     "[0:a][click]amix=inputs=2:duration=first",
                     "-c:a", "pcm_s16le", str(pre_pause)],
                    check=True, capture_output=True,
                )
            else:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(pre_ambient),
                     "-c:a", "pcm_s16le", str(pre_pause)],
                    check=True, capture_output=True,
                )

            # Build post-pause: ambient (matched to next clip) with click_down
            is_last = i == len(audio_clips) - 1
            post_ambient = ambient_path
            post_pause = tmpdir / f"post_{i:02d}.wav"
            if click_down_path and not is_last:
                click_offset = max(0, pause - 0.075)
                subprocess.run(
                    ["ffmpeg", "-y",
                     "-i", str(post_ambient), "-i", str(click_down_path),
                     "-filter_complex",
                     f"[1:a]adelay={int(click_offset * 1000)}|{int(click_offset * 1000)},apad=whole_dur=0[click];"
                     "[0:a][click]amix=inputs=2:duration=first",
                     "-c:a", "pcm_s16le", str(post_pause)],
                    check=True, capture_output=True,
                )
            else:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(post_ambient),
                     "-c:a", "pcm_s16le", str(post_pause)],
                    check=True, capture_output=True,
                )

            # Concat: pre_pause + narration + post_pause
            padded_audio = tmpdir / f"padded_{i:02d}.wav"
            subprocess.run(
                ["ffmpeg", "-y",
                 "-i", str(pre_pause), "-i", str(audio_clip),
                 "-i", str(post_pause),
                 "-filter_complex",
                 "[0:a][1:a][2:a]concat=n=3:v=0:a=1",
                 "-c:a", "pcm_s16le", str(padded_audio)],
                check=True, capture_output=True,
            )

            duration = get_audio_duration(padded_audio)

            segment_path = tmpdir / f"segment_{i:02d}.mp4"
            subprocess.run(
                ["ffmpeg", "-y",
                 "-loop", "1", "-i", str(slide_img),
                 "-i", str(padded_audio),
                 "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                 "-c:v", "libx264", "-tune", "stillimage",
                 "-c:a", "aac", "-b:a", "192k",
                 "-pix_fmt", "yuv420p",
                 "-t", str(duration),
                 "-shortest",
                 str(segment_path)],
                check=True, capture_output=True,
            )
            segment_paths.append(segment_path)
            total_duration += duration
            narration_dur = get_audio_duration(audio_clip)
            print(f"  Slide {slide_num}: {narration_dur:.1f}s + {pause}s pause")

        # Concatenate all segments
        concat_file = tmpdir / "concat.txt"
        concat_file.write_text(
            "\n".join(f"file '{p}'" for p in segment_paths)
        )
        subprocess.run(
            ["ffmpeg", "-y", "-f", "concat", "-safe", "0",
             "-i", str(concat_file), "-c", "copy", str(output_path)],
            check=True, capture_output=True,
        )

        print(f"\nTotal duration: {total_duration:.1f}s ({total_duration / 60:.1f} min)")


def main():
    parser = argparse.ArgumentParser(
        description="Generate a narrated presentation video from slides, a script, "
        "and a voice sample."
    )
    parser.add_argument(
        "--slides", type=Path, required=True, help="Path to slides PDF",
    )
    parser.add_argument(
        "--script", type=Path, required=True,
        help="Path to narration script (markdown)",
    )
    parser.add_argument(
        "--voice", type=Path, required=True, nargs="+",
        help="Path to voice sample(s). Multiple files are merged for better cloning.",
    )
    parser.add_argument(
        "--output", type=Path, default=Path("output.mp4"),
        help="Output video path",
    )
    parser.add_argument(
        "--pause", type=float, default=1.0,
        help="Seconds of pause before narration on each slide (default: 1.0)",
    )
    parser.add_argument(
        "--device", type=str, default="cuda",
        help="PyTorch device for TTS model",
    )
    parser.add_argument(
        "--tts-engine", type=str, default="chatterbox", choices=sorted(ENGINES),
        help="TTS engine for voice cloning (default: chatterbox)",
    )
    parser.add_argument(
        "--language", type=str, default="en",
        help="Language code for TTS, e.g. en, zh, fr, de, es (default: en)",
    )
    parser.add_argument(
        "--speed", type=float, default=None,
        help="Playback speed multiplier for narration, e.g. 1.2 for 20%% faster",
    )
    parser.add_argument(
        "--only-slides", type=str, default=None, metavar="RANGE",
        help="Only process specific slides, e.g. '3-7' or '1,3,5-7'",
    )
    parser.add_argument(
        "--preview", action="store_true",
        help="Generate audio only, skip video assembly (for quick iteration)",
    )
    parser.add_argument(
        "--srt", type=Path, default=None, metavar="PATH",
        help="Export SRT subtitles to the given path",
    )
    parser.add_argument(
        "--click-sound", type=Path, default=None, metavar="PATH",
        help="Path to a click sound effect to play at each slide transition",
    )
    parser.add_argument(
        "--cache-dir", type=Path, default=Path(".cache"),
        help="Directory for intermediate files",
    )
    parser.add_argument(
        "--regenerate", action="store_true",
        help="Regenerate all audio clips (ignore cache)",
    )
    parser.add_argument(
        "--regenerate-slide", type=int, nargs="+", metavar="N",
        help="Regenerate audio for specific slide(s) only, e.g. --regenerate-slide 3 7",
    )
    args = parser.parse_args()

    audio_dir = args.cache_dir / "audio_clips"
    slides_dir = args.cache_dir / "slide_images"

    if args.regenerate:
        import shutil
        if audio_dir.exists():
            shutil.rmtree(audio_dir)
    elif args.regenerate_slide:
        for slide_num in args.regenerate_slide:
            cached = audio_dir / f"slide_{slide_num:02d}.wav"
            if cached.exists():
                cached.unlink()
                print(f"Cleared cached audio for slide {slide_num}")

    print("Parsing script...")
    slides = parse_script(args.script)
    print(f"  Found {len(slides)} slides\n")

    # Filter to requested slides
    if args.only_slides:
        requested = parse_slide_range(args.only_slides)
        slides = [(n, t) for n, t in slides if n in requested]
        print(f"  Filtered to {len(slides)} slides: {sorted(n for n, _ in slides)}\n")

    print("Preparing voice sample...")
    args.cache_dir.mkdir(exist_ok=True)
    voice_wav = merge_voice_samples(
        args.voice, args.cache_dir / "voice_merged.wav",
    )
    if len(args.voice) > 1:
        print(f"  Merged {len(args.voice)} voice samples")
    print()

    print(f"Loading TTS engine ({args.tts_engine})...")
    engine = get_engine(args.tts_engine)
    engine.load(args.device)
    print()

    print("Generating audio clips...")
    audio_clips = generate_audio_clips(
        slides, engine, voice_wav, audio_dir, language=args.language,
    )
    print()

    if args.preview:
        import soundfile as sf_read
        print("Preview mode: skipping video assembly.")
        print("Audio clips:")
        for clip in audio_clips:
            info = sf_read.info(str(clip))
            print(f"  {clip.name}: {info.duration:.1f}s")
        return

    print("Extracting slide images...")
    slide_images = extract_slide_images(args.slides, slides_dir)
    print()

    if args.srt:
        print("Generating subtitles...")
        generate_srt(slides, audio_clips, args.srt, pause=args.pause)
        print()

    print("Assembling video...")
    assemble_video(
        slide_images, audio_clips, slides, args.output,
        engine=engine, voice_wav_path=voice_wav,
        language=args.language, pause=args.pause,
        speed=args.speed, click_sound=args.click_sound,
    )
    print(f"\nDone! Saved to {args.output}")


if __name__ == "__main__":
    main()
