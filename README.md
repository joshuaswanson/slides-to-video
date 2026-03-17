# slides-to-video

Generate narrated presentation videos from a slide deck, a script, and a voice sample. Uses [Chatterbox](https://github.com/resemble-ai/chatterbox) for zero-shot voice cloning, so you only need ~10 seconds of audio to clone your voice.

All processing runs locally. Your voice data never leaves your machine.

## How it works

1. You provide three inputs:
   - A **PDF slide deck**
   - A **markdown script** with narration text per slide
   - A **voice sample** (any audio format, ~10 seconds)

2. The tool clones your voice, generates narration for each slide, and assembles everything into an MP4 video with configurable pauses between slides.

## Requirements

- Python 3.10+
- NVIDIA GPU with CUDA support
- `ffmpeg` and `pdftoppm` (from `poppler-utils`) installed and in PATH

## Installation

```bash
pip install chatterbox-tts torchaudio
```

## Usage

```bash
python generate.py \
    --slides presentation.pdf \
    --script script.md \
    --voice voice_sample.wav \
    --output presentation_video.mp4 \
    --pause 1.0
```

### Options

| Flag           | Default      | Description                                             |
| -------------- | ------------ | ------------------------------------------------------- |
| `--slides`     | (required)   | Path to slides PDF                                      |
| `--script`     | (required)   | Path to narration script (markdown)                     |
| `--voice`      | (required)   | Path to voice sample (WAV, MP3, M4A, etc.)              |
| `--output`     | `output.mp4` | Output video path                                       |
| `--pause`      | `1.0`        | Seconds of silence before narration on each slide       |
| `--device`     | `cuda`       | PyTorch device (`cuda`, `cpu`)                          |
| `--cache-dir`  | `.cache`     | Directory for intermediate audio clips and slide images |
| `--regenerate` | off          | Force regeneration of all audio clips (ignore cache)    |

### Script format

The script is a markdown file with slides separated by `---`. Each slide section starts with a heading containing the slide number:

```markdown
## Slide 1 - Title

This is the narration for the first slide.

---

## Slide 2 - Introduction

This is the narration for the second slide. You can write
multiple lines and they will be joined together.

---

## Slide 3 - Results

Here are our results.
```

The slide number in the heading determines which PDF page the narration is paired with. Slides without narration are skipped.

### Caching

Audio clips and slide images are cached in `.cache/` by default. If you change only the script, previously generated clips for unchanged slides will be reused. Use `--regenerate` to force fresh generation of all audio.

## How voice cloning works

Chatterbox performs zero-shot voice cloning from a short audio sample (~5-10 seconds). The model runs entirely locally on your GPU. No data is sent to any external service.

For best results, use a clean recording of natural speech without background noise.

## Support

If you find this useful, [buy me a coffee](https://buymeacoffee.com/swanson).

<img src="assets/bmc_qr.png" alt="Buy Me a Coffee QR" width="200">
