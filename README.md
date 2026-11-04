# slides-to-video

Turn slide decks into narrated videos with AI voice cloning. Provide a PDF, a markdown script, and a voice sample of about 5 seconds, and get a presentation video.

All processing runs locally on your GPU. Your voice data never leaves your machine.

## Features

- **Multiple TTS engines**: Qwen3-TTS (10 languages), Chatterbox (English)
- **Voice cloning** from a short audio sample. Multiple samples are concatenated.
- **Caching**: audio is regenerated only for slides whose text, voice, engine, or language changed
- **Web editor** for editing the script, generating audio per slide, previewing the full talk, and exporting
- **Click sounds** at slide transitions, with the slide changing between key press and release
- **Ambient pauses** filled with the TTS model's own background noise
- **SRT subtitles** aligned to the narration
- **Speed control** and inline `[pause]` markers

## Requirements

- Python 3.10 to 3.13
- An NVIDIA GPU with CUDA for practical generation speed
- `ffmpeg` and `pdftoppm` (from `poppler-utils`) on `PATH`

## Installation

```bash
uv sync --group qwen3                       # Qwen3-TTS
uv sync --group chatterbox --python 3.11    # or Chatterbox
```

Chatterbox's dependencies pin old packages without Python 3.12 wheels, so its environment needs Python 3.10 or 3.11.

## Quick Start (CLI)

```bash
uv run slides-to-video \
    --slides presentation.pdf \
    --script script.md \
    --voice voice_sample.wav \
    --tts-engine qwen3 \
    --click-sound
```

## Web Editor

```bash
uv run slides-to-video-editor --script script.md --slides presentation.pdf --voice voice_sample.wav --tts-engine qwen3
```

Open http://localhost:8000. Without `--tts-engine`, select an engine in Settings before generating. Cached clips only count as current for the engine that made them. Slides, the voice sample, the engine, language, pause, speed, and click sound can also be set from the Settings panel.

The editor has no authentication and binds to `127.0.0.1` by default. On a remote GPU machine, reach it through an SSH tunnel:

```bash
ssh -L 8000:localhost:8000 gpu-host
```

Editor options: `--script` (default `script.md`), `--slides`, `--voice`, `--cache-dir`, `--tts-engine`, `--device`, `--language`, `--click-sound`, `--height`, `--host`, `--port`.

## CLI Options

| Flag                 | Default      | Description                                                              |
| -------------------- | ------------ | ------------------------------------------------------------------------ |
| `--slides`           | (required)   | Path to slides PDF                                                       |
| `--script`           | (required)   | Path to narration script (markdown)                                      |
| `--voice`            | (required)   | Path to voice sample(s). Multiple files are concatenated.                |
| `--output`           | `output.mp4` | Output video path                                                        |
| `--tts-engine`       | (required)   | TTS engine (`qwen3`, `chatterbox`)                                       |
| `--language`         | `en`         | Language code (en, zh, ja, ko, fr, de, es, ar, ru, pt). Chatterbox: en.  |
| `--pause`            | `1.0`        | Seconds of ambient pause before and after each slide's narration         |
| `--speed`            | (none)       | Narration speed multiplier (e.g. 1.2 for 20% faster), at least 0.5       |
| `--click-sound`      | (none)       | Click at slide transitions. Without a path, uses the bundled click.      |
| `--height`           | `1080`       | Video height in pixels                                                   |
| `--only-slides`      | (none)       | Process specific slides only (e.g. `3-7` or `1,3,5`)                     |
| `--preview`          | off          | Generate audio only, skip video assembly                                 |
| `--srt`              | (none)       | Export SRT subtitles to the given path                                   |
| `--regenerate`       | off          | Force regeneration of all audio clips                                    |
| `--regenerate-slide` | (none)       | Regenerate specific slides (e.g. `--regenerate-slide 3 7`)               |
| `--device`           | `cuda`       | PyTorch device                                                           |
| `--cache-dir`        | `.cache`     | Directory for cached audio clips and slide images                        |

## Script Format

Slides are separated by lines containing only `---`. Each slide starts with a `## Slide N` heading, where `N` is the PDF page number:

```markdown
## Slide 1 - Title

This is the narration for the first slide.

---

## Slide 2 - Introduction

Paragraphs and line breaks are kept in the file and joined for narration.

Use [pause] for a 0.5 second pause, or [pause 1.5] for a custom duration.
```

A slide with a heading and no narration is shown for the two pauses only.

## Timing

Each slide occupies `[pause][narration][pause]`. The click sound is placed so the slide image changes between the key press and the release. The editor's Play All preview, the exported video, and the SRT file all use the same narration track.

## Caching

Everything is cached in `.cache/` by default:

- `audio_clips/` holds one WAV per slide. A clip is reused while the slide's narration, the voice sample, the engine, and the language are unchanged.
- `slide_images/` holds the rendered pages and thumbnails. They are re-rendered when the PDF contents or `--height` change.
- `voice.wav` is the prepared voice sample. The editor reuses it across restarts.

Use `--regenerate` to redo all audio, or `--regenerate-slide 3 7` to redo specific slides.

## Development

```bash
uv run pytest
```

The tests use a fake TTS engine and need `ffmpeg` and `pdftoppm`, but no GPU or model download.

## Project Structure

```
src/slides_to_video/
  cli.py            # slides-to-video command
  server.py         # slides-to-video-editor command (FastAPI)
  script.py         # script parsing and editing
  audio.py          # voice preparation, TTS clips, narration track
  video.py          # slide rendering, video encoding, subtitles
  tts_engines.py    # Qwen3 and Chatterbox engines
  web/editor.html   # editor frontend
  assets/click.wav  # bundled transition click
examples/
  example_script.md
tests/
```

## Support

If you find this useful, [buy me a coffee](https://buymeacoffee.com/swanson).

<img src="assets/bmc_qr.png" alt="Buy Me a Coffee QR" width="200">
