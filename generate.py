"""Generate a narrated presentation video from slides, a script, and a voice sample.

Usage:
    python generate.py --slides presentation.pdf --script script.md --voice voice.m4a

Requires:
    - A GPU with CUDA support (for Chatterbox TTS voice cloning)
    - ffmpeg and pdftoppm installed

The script should be a markdown file with slide sections separated by '---':

    ## Slide 1 - Title
    Text to narrate for slide 1.

    ---

    ## Slide 2 - Introduction
    Text to narrate for slide 2.
"""

import argparse
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import torchaudio
from chatterbox.tts import ChatterboxTTS


def _find_ffmpeg() -> str:
    """Find ffmpeg binary, falling back to imageio-ffmpeg if not in PATH."""
    if shutil.which("ffmpeg"):
        return "ffmpeg"
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        raise RuntimeError("ffmpeg not found. Install it or run: pip install imageio[ffmpeg]")


FFMPEG = _find_ffmpeg()


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


def convert_voice_sample(voice_path: Path, output_path: Path) -> Path:
    """Convert voice sample to WAV if needed."""
    if voice_path.suffix == ".wav":
        return voice_path
    subprocess.run(
        [FFMPEG, "-y", "-i", str(voice_path), "-ar", "24000", "-ac", "1", str(output_path)],
        check=True,
        capture_output=True,
    )
    return output_path


def generate_audio_clips(
    slides: list[tuple[int, str]],
    model: ChatterboxTTS,
    voice_wav_path: Path,
    output_dir: Path,
) -> list[Path]:
    """Generate TTS audio for each slide using the cloned voice."""
    output_dir.mkdir(exist_ok=True)
    clip_paths = []
    for slide_num, text in slides:
        out_path = output_dir / f"slide_{slide_num:02d}.wav"
        if out_path.exists():
            print(f"  Slide {slide_num}: using cached audio")
            clip_paths.append(out_path)
            continue
        print(f"  Slide {slide_num}: generating...")
        wav = model.generate(text, audio_prompt_path=str(voice_wav_path))
        torchaudio.save(str(out_path), wav, model.sr)
        duration = wav.shape[1] / model.sr
        print(f"  Slide {slide_num}: {duration:.1f}s")
        clip_paths.append(out_path)
    return clip_paths


def extract_slide_images(pdf_path: Path, output_dir: Path) -> list[Path]:
    """Convert PDF pages to PNG images."""
    output_dir.mkdir(exist_ok=True)
    existing = sorted(output_dir.glob("slide-*.png"))
    if existing:
        print(f"  Using {len(existing)} cached slide images")
        return existing
    subprocess.run(
        ["pdftoppm", "-png", "-r", "300", str(pdf_path), str(output_dir / "slide")],
        check=True,
        capture_output=True,
    )
    return sorted(output_dir.glob("slide-*.png"))


def get_audio_duration(audio_path: Path) -> float:
    """Get duration of a WAV file in seconds."""
    info = torchaudio.info(str(audio_path))
    return info.num_frames / info.sample_rate


def assemble_video(
    slide_images: list[Path],
    audio_clips: list[Path],
    slides: list[tuple[int, str]],
    output_path: Path,
    pause: float,
) -> None:
    """Stitch slide images and audio clips into a video with pauses between slides."""
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Generate a silence file for the pause
        silence_path = tmpdir / "silence.wav"
        subprocess.run(
            [FFMPEG, "-y", "-f", "lavfi", "-t", str(pause),
             "-i", "anullsrc=r=24000:cl=mono", "-c:a", "pcm_s16le",
             str(silence_path)],
            check=True, capture_output=True,
        )

        segment_paths = []
        total_duration = 0.0

        for i, (audio_clip, (slide_num, _)) in enumerate(zip(audio_clips, slides)):
            slide_img = slide_images[slide_num - 1]
            duration = get_audio_duration(audio_clip)
            segment_duration = duration + pause

            # Prepend silence so narration starts after the pause
            padded_audio = tmpdir / f"padded_{i:02d}.wav"
            subprocess.run(
                [FFMPEG, "-y", "-i", str(silence_path), "-i", str(audio_clip),
                 "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1",
                 "-c:a", "pcm_s16le", str(padded_audio)],
                check=True, capture_output=True,
            )

            segment_path = tmpdir / f"segment_{i:02d}.mp4"
            subprocess.run(
                [FFMPEG, "-y",
                 "-loop", "1", "-i", str(slide_img),
                 "-i", str(padded_audio),
                 "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                 "-c:v", "libx264", "-tune", "stillimage",
                 "-c:a", "aac", "-b:a", "192k",
                 "-pix_fmt", "yuv420p",
                 "-t", str(segment_duration),
                 "-shortest",
                 str(segment_path)],
                check=True, capture_output=True,
            )
            segment_paths.append(segment_path)
            total_duration += segment_duration
            print(f"  Slide {slide_num}: {duration:.1f}s + {pause}s pause")

        # Concatenate all segments
        concat_file = tmpdir / "concat.txt"
        concat_file.write_text(
            "\n".join(f"file '{p}'" for p in segment_paths)
        )
        subprocess.run(
            [FFMPEG, "-y", "-f", "concat", "-safe", "0",
             "-i", str(concat_file), "-c", "copy", str(output_path)],
            check=True, capture_output=True,
        )

        print(f"\nTotal duration: {total_duration:.1f}s ({total_duration / 60:.1f} min)")


def main():
    parser = argparse.ArgumentParser(
        description="Generate a narrated presentation video from slides, a script, and a voice sample."
    )
    parser.add_argument("--slides", type=Path, required=True, help="Path to slides PDF")
    parser.add_argument("--script", type=Path, required=True, help="Path to narration script (markdown)")
    parser.add_argument("--voice", type=Path, required=True, help="Path to voice sample (any audio format)")
    parser.add_argument("--output", type=Path, default=Path("output.mp4"), help="Output video path")
    parser.add_argument("--pause", type=float, default=1.0, help="Seconds of silence before narration on each slide")
    parser.add_argument("--device", type=str, default="cuda", help="PyTorch device for TTS model")
    parser.add_argument("--cache-dir", type=Path, default=Path(".cache"), help="Directory for intermediate files")
    parser.add_argument("--regenerate", action="store_true", help="Regenerate all audio clips (ignore cache)")
    args = parser.parse_args()

    audio_dir = args.cache_dir / "audio_clips"
    slides_dir = args.cache_dir / "slide_images"

    if args.regenerate:
        import shutil
        if audio_dir.exists():
            shutil.rmtree(audio_dir)

    print("Parsing script...")
    slides = parse_script(args.script)
    print(f"  Found {len(slides)} slides\n")

    args.cache_dir.mkdir(exist_ok=True)

    print("Converting voice sample...")
    voice_wav = convert_voice_sample(args.voice, args.cache_dir / "voice_converted.wav")
    print()

    print("Loading TTS model...")
    model = ChatterboxTTS.from_pretrained(args.device)
    print()

    print("Generating audio clips...")
    audio_clips = generate_audio_clips(slides, model, voice_wav, audio_dir)
    print()

    print("Extracting slide images...")
    slide_images = extract_slide_images(args.slides, slides_dir)
    print()

    print("Assembling video...")
    assemble_video(slide_images, audio_clips, slides, args.output, args.pause)
    print(f"\nDone! Saved to {args.output}")


if __name__ == "__main__":
    main()
