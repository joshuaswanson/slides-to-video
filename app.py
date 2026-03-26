"""Gradio web UI for slides-to-video.

Launch with: uv run app.py
Then open the URL in your browser.
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import gradio as gr
import soundfile as sf

from generate import (
    parse_script,
    extract_slide_images,
    generate_audio_clips,
    get_audio_duration,
    assemble_video,
    convert_voice_sample,
    _generate_slide_audio,
    _text_hash,
    _load_cache_hashes,
    _save_cache_hashes,
)
from tts_engines import get_engine, ENGINES

WORK_DIR = Path(".cache")
AUDIO_DIR = WORK_DIR / "audio_clips"
SLIDES_DIR = WORK_DIR / "slide_images"

engine = None
engine_name = None
voice_wav_path = None


def load_engine(tts_engine: str, device: str) -> str:
    global engine, engine_name
    if engine_name == tts_engine and engine is not None:
        return f"Engine '{tts_engine}' already loaded."
    engine = get_engine(tts_engine)
    engine.load(device)
    engine_name = tts_engine
    return f"Loaded '{tts_engine}' on {device}."


def set_voice(voice_file: str) -> str:
    global voice_wav_path
    if voice_file is None:
        return "No voice file uploaded."
    WORK_DIR.mkdir(exist_ok=True)
    dest = WORK_DIR / "voice_converted.wav"
    voice_wav_path = convert_voice_sample(Path(voice_file), dest)
    return f"Voice sample ready: {voice_wav_path.name}"


def load_slides(pdf_file: str) -> list[str]:
    if pdf_file is None:
        return []
    images = extract_slide_images(Path(pdf_file), SLIDES_DIR)
    return [str(img) for img in images]


def parse_and_preview(script_text: str):
    """Parse script and return slide data for the UI."""
    if not script_text.strip():
        return [], "No script provided."

    # Write to temp file for parse_script
    tmp = WORK_DIR / "script_tmp.md"
    WORK_DIR.mkdir(exist_ok=True)
    tmp.write_text(script_text)
    slides = parse_script(tmp)

    rows = []
    AUDIO_DIR.mkdir(exist_ok=True)
    hashes = _load_cache_hashes(AUDIO_DIR / "hashes.json")

    for slide_num, text in slides:
        audio_path = AUDIO_DIR / f"slide_{slide_num:02d}.wav"
        key = f"slide_{slide_num:02d}"
        current_hash = _text_hash(text)
        cached = audio_path.exists() and hashes.get(key) == current_hash

        if cached:
            dur = sf.info(str(audio_path)).duration
            status = f"Cached ({dur:.1f}s)"
        elif audio_path.exists():
            status = "Script changed"
        else:
            status = "Not generated"

        rows.append({
            "Slide": slide_num,
            "Text": text[:80] + ("..." if len(text) > 80 else ""),
            "Status": status,
        })

    return rows, f"Found {len(slides)} slides."


def generate_single_slide(slide_num: int, script_text: str, language: str) -> str:
    """Generate or regenerate audio for a single slide."""
    if engine is None:
        return "Load TTS engine first."
    if voice_wav_path is None:
        return "Upload voice sample first."

    tmp = WORK_DIR / "script_tmp.md"
    tmp.write_text(script_text)
    slides = parse_script(tmp)

    target = None
    for num, text in slides:
        if num == slide_num:
            target = (num, text)
            break

    if target is None:
        return f"Slide {slide_num} not found in script."

    num, text = target
    AUDIO_DIR.mkdir(exist_ok=True)
    out_path = AUDIO_DIR / f"slide_{num:02d}.wav"
    if out_path.exists():
        out_path.unlink()

    duration = _generate_slide_audio(text, engine, voice_wav_path, out_path, language)
    hashes = _load_cache_hashes(AUDIO_DIR / "hashes.json")
    hashes[f"slide_{num:02d}"] = _text_hash(text)
    _save_cache_hashes(AUDIO_DIR / "hashes.json", hashes)

    return f"Slide {num}: {duration:.1f}s"


def generate_all_audio(script_text: str, language: str, progress=gr.Progress()) -> str:
    """Generate audio for all slides (respects cache)."""
    if engine is None:
        return "Load TTS engine first."
    if voice_wav_path is None:
        return "Upload voice sample first."

    tmp = WORK_DIR / "script_tmp.md"
    tmp.write_text(script_text)
    slides = parse_script(tmp)

    progress(0, desc="Generating audio...")
    clips = generate_audio_clips(slides, engine, voice_wav_path, AUDIO_DIR, language)
    total = sum(sf.info(str(c)).duration for c in clips)
    return f"Generated {len(clips)} clips, total {total:.1f}s."


def get_slide_audio(slide_num: int) -> str | None:
    """Return path to a slide's audio for playback."""
    audio_path = AUDIO_DIR / f"slide_{slide_num:02d}.wav"
    if audio_path.exists():
        return str(audio_path)
    return None


def build_video(
    script_text: str,
    pdf_file: str,
    language: str,
    pause: float,
    use_click: bool,
    progress=gr.Progress(),
) -> str | None:
    """Assemble the final video."""
    if engine is None:
        return None
    if voice_wav_path is None:
        return None
    if pdf_file is None:
        return None

    tmp = WORK_DIR / "script_tmp.md"
    tmp.write_text(script_text)
    slides = parse_script(tmp)

    progress(0.1, desc="Checking audio clips...")
    clips = generate_audio_clips(slides, engine, voice_wav_path, AUDIO_DIR, language)

    progress(0.3, desc="Extracting slide images...")
    images = extract_slide_images(Path(pdf_file), SLIDES_DIR)

    click_path = Path("click.wav") if use_click and Path("click.wav").exists() else None

    progress(0.5, desc="Assembling video...")
    output = WORK_DIR / "video.mp4"
    assemble_video(
        images, clips, slides, output,
        engine=engine, voice_wav_path=voice_wav_path,
        language=language, pause=pause, click_sound=click_path,
    )

    progress(1.0, desc="Done!")
    return str(output)


def build_ui():
    with gr.Blocks(title="Slides to Video", theme=gr.themes.Soft()) as app:
        gr.Markdown("# Slides to Video\nGenerate narrated presentation videos with voice cloning.")

        with gr.Row():
            with gr.Column(scale=1):
                gr.Markdown("### Setup")
                tts_choice = gr.Dropdown(
                    choices=sorted(ENGINES.keys()),
                    value="qwen3",
                    label="TTS Engine",
                )
                device_choice = gr.Dropdown(
                    choices=["cuda", "cuda:0", "cuda:1", "cpu"],
                    value="cuda",
                    label="Device",
                )
                load_btn = gr.Button("Load Engine", variant="primary")
                engine_status = gr.Textbox(label="Engine Status", interactive=False)
                load_btn.click(load_engine, [tts_choice, device_choice], engine_status)

                voice_upload = gr.Audio(label="Voice Sample", type="filepath")
                voice_status = gr.Textbox(label="Voice Status", interactive=False)
                voice_upload.change(set_voice, voice_upload, voice_status)

                pdf_upload = gr.File(label="Slides PDF", file_types=[".pdf"])
                language = gr.Dropdown(
                    choices=["en", "zh", "ja", "ko", "fr", "de", "es", "ar", "ru", "pt"],
                    value="en",
                    label="Language",
                )
                pause_slider = gr.Slider(0.5, 3.0, value=1.0, step=0.1, label="Pause (seconds)")
                use_click = gr.Checkbox(value=True, label="Click sound at transitions")

            with gr.Column(scale=2):
                gr.Markdown("### Script")
                script_box = gr.Textbox(
                    label="Narration Script (Markdown)",
                    lines=20,
                    placeholder="## Slide 1 - Title\nYour narration text here.\n\n---\n\n## Slide 2 - Overview\n...",
                )
                with gr.Row():
                    parse_btn = gr.Button("Parse Script")
                    gen_all_btn = gr.Button("Generate All Audio", variant="primary")
                parse_status = gr.Textbox(label="Status", interactive=False)

                slide_table = gr.Dataframe(
                    headers=["Slide", "Text", "Status"],
                    label="Slides",
                    interactive=False,
                )
                parse_btn.click(parse_and_preview, script_box, [slide_table, parse_status])
                gen_all_btn.click(generate_all_audio, [script_box, language], parse_status)

        gr.Markdown("### Per-slide controls")
        with gr.Row():
            slide_num_input = gr.Number(label="Slide Number", value=1, precision=0)
            regen_btn = gr.Button("Regenerate This Slide")
            play_btn = gr.Button("Play This Slide")
        regen_status = gr.Textbox(label="Regenerate Status", interactive=False)
        slide_audio = gr.Audio(label="Slide Audio", interactive=False)

        regen_btn.click(
            generate_single_slide,
            [slide_num_input, script_box, language],
            regen_status,
        )
        play_btn.click(get_slide_audio, slide_num_input, slide_audio)

        gr.Markdown("### Export")
        with gr.Row():
            build_btn = gr.Button("Build Video", variant="primary", size="lg")
        video_output = gr.Video(label="Output Video")
        build_btn.click(
            build_video,
            [script_box, pdf_upload, language, pause_slider, use_click],
            video_output,
        )

    return app


if __name__ == "__main__":
    app = build_ui()
    app.launch(server_name="0.0.0.0", server_port=7860, share=False)
