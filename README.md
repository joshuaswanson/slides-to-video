# slides-to-video

Turn slide decks into narrated videos with AI voice cloning. Upload a PDF, write a script, provide a ~5 second voice sample, and get a professional presentation video.

All processing runs locally on your GPU. Your voice data never leaves your machine.

## Features

- **Multiple TTS engines**: Qwen3-TTS (recommended), Chatterbox
- **Voice cloning**: Clone your voice from a short audio sample (~5 seconds)
- **Multilingual**: Generate narration in 10 languages (en, zh, ja, ko, fr, de, es, ar, ru, pt)
- **Smart caching**: Only regenerates audio for slides where the script changed
- **Web editor**: Professional video-editor-style UI for previewing and editing
- **Click sounds**: Optional slide transition click effects
- **Ambient noise matching**: Natural-sounding pauses between slides
- **Per-slide regeneration**: Quickly iterate on individual slides
- **SRT subtitles**: Export subtitle files alongside your video
- **Speed control**: Adjust narration speed
- **Inline pauses**: Use `[pause]` markers in your script for dramatic pauses

## Web Editor

The built-in editor provides a Final Cut Pro-style interface:

- Slide preview with timeline navigation
- Live script editing with auto-save
- Per-slide audio generation and playback
- Full presentation playback with ambient pauses and click sounds
- One-click video export

```bash
uv run src/server.py
# Open http://localhost:8000
```

## Quick Start (CLI)

```bash
uv run src/generate.py \
    --slides presentation.pdf \
    --script script.md \
    --voice voice_sample.wav \
    --tts-engine qwen3 \
    --click-sound assets/click.wav
```

## Requirements

- Python 3.10+
- NVIDIA GPU with CUDA support
- `ffmpeg` and `pdftoppm` (from `poppler-utils`) installed and in PATH

## Installation

```bash
# Install with Qwen3-TTS (recommended)
uv sync --group qwen3

# Or with Chatterbox
uv sync --group chatterbox
```

## CLI Options

| Flag                 | Default      | Description                                                        |
| -------------------- | ------------ | ------------------------------------------------------------------ |
| `--slides`           | (required)   | Path to slides PDF                                                 |
| `--script`           | (required)   | Path to narration script (markdown)                                |
| `--voice`            | (required)   | Path to voice sample(s). Multiple files merged for better cloning. |
| `--output`           | `output.mp4` | Output video path                                                  |
| `--tts-engine`       | `chatterbox` | TTS engine (`chatterbox`, `qwen3`)                                 |
| `--language`         | `en`         | Language code (en, zh, ja, ko, fr, de, es, ar, ru, pt)             |
| `--pause`            | `1.0`        | Seconds of pause between slides                                    |
| `--speed`            | (none)       | Playback speed multiplier (e.g. 1.2 for 20% faster)                |
| `--click-sound`      | (none)       | Path to click sound effect for slide transitions                   |
| `--only-slides`      | (none)       | Process specific slides only (e.g. `3-7` or `1,3,5`)               |
| `--preview`          | off          | Generate audio only, skip video assembly                           |
| `--srt`              | (none)       | Export SRT subtitles to the given path                             |
| `--regenerate`       | off          | Force regeneration of all audio clips                              |
| `--regenerate-slide` | (none)       | Regenerate specific slides (e.g. `--regenerate-slide 3 7`)         |
| `--device`           | `cuda`       | PyTorch device                                                     |
| `--cache-dir`        | `.cache`     | Directory for cached audio clips and slide images                  |

## Script Format

The script is a markdown file with slides separated by `---`:

```markdown
## Slide 1 - Title

This is the narration for the first slide.

---

## Slide 2 - Introduction

This is the narration for the second slide. You can write
multiple lines and they will be joined together.

Use [pause] for a 0.5 second pause, or [pause 1.5] for custom duration.
```

## Caching

Audio clips and slide images are cached in `.cache/` by default. The system hashes each slide's script text, so if you change only one slide, only that slide's audio gets regenerated. Use `--regenerate` to force fresh generation of all audio, or `--regenerate-slide 3 7` to redo specific slides.

## Project Structure

```
src/
  generate.py       # Core generation pipeline
  tts_engines.py    # TTS engine abstraction (Qwen3, Chatterbox)
  server.py         # FastAPI backend for the web editor
web/
  editor.html       # Video editor frontend
assets/
  click.wav         # Slide transition click sound
examples/
  example_script.md # Example narration script
```

## Support

If you find this useful, [buy me a coffee](https://buymeacoffee.com/swanson).

<img src="assets/bmc_qr.png" alt="Buy Me a Coffee QR" width="200">
