"""FastAPI backend for the slides-to-video editor.

Launch with: uv run server.py
Then open http://localhost:8000 in your browser.
"""

from __future__ import annotations

import json
from pathlib import Path

import soundfile as sf
from fastapi import FastAPI, File, UploadFile, Form
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

from generate import (
    parse_script,
    extract_slide_images,
    generate_audio_clips,
    assemble_video,
    convert_voice_sample,
    _generate_slide_audio,
    _text_hash,
    _load_cache_hashes,
    _save_cache_hashes,
)
from tts_engines import get_engine, ENGINES

app = FastAPI()

WORK_DIR = Path(".cache")
AUDIO_DIR = WORK_DIR / "audio_clips"
SLIDES_DIR = WORK_DIR / "slide_images"
SCRIPT_PATH = Path("script.md")

engine = None
engine_name = None
voice_wav_path = None


def _parse_current_script() -> list[tuple[int, str]]:
    if SCRIPT_PATH.exists():
        return parse_script(SCRIPT_PATH)
    return []


@app.get("/")
async def index():
    return FileResponse("editor.html")


@app.post("/api/load-engine")
async def api_load_engine(tts_engine: str = Form("qwen3"), device: str = Form("cuda")):
    global engine, engine_name
    if engine_name == tts_engine and engine is not None:
        return {"status": "ok", "message": f"Engine '{tts_engine}' already loaded."}
    engine = get_engine(tts_engine)
    engine.load(device)
    engine_name = tts_engine
    return {"status": "ok", "message": f"Loaded '{tts_engine}' on {device}."}


@app.post("/api/upload-voice")
async def api_upload_voice(file: UploadFile = File(...)):
    global voice_wav_path
    WORK_DIR.mkdir(exist_ok=True)
    upload_path = WORK_DIR / f"voice_upload{Path(file.filename).suffix}"
    upload_path.write_bytes(await file.read())
    voice_wav_path = convert_voice_sample(upload_path, WORK_DIR / "voice_converted.wav")
    return {"status": "ok", "message": f"Voice sample ready."}


@app.get("/api/slides")
async def api_slides():
    slides = _parse_current_script()
    AUDIO_DIR.mkdir(exist_ok=True)
    hashes = _load_cache_hashes(AUDIO_DIR / "hashes.json")
    slide_images = sorted(SLIDES_DIR.glob("slide-*.png")) if SLIDES_DIR.exists() else []

    result = []
    for slide_num, text in slides:
        audio_path = AUDIO_DIR / f"slide_{slide_num:02d}.wav"
        key = f"slide_{slide_num:02d}"
        current_hash = _text_hash(text)
        has_audio = audio_path.exists() and hashes.get(key) == current_hash
        duration = sf.info(str(audio_path)).duration if audio_path.exists() else 0

        result.append({
            "slide_num": slide_num,
            "text": text,
            "has_audio": has_audio,
            "duration": round(duration, 1),
            "image_url": f"/api/slide-image/{slide_num}",
        })

    return result


@app.get("/api/slide-image/{slide_num}")
async def api_slide_image(slide_num: int):
    images = sorted(SLIDES_DIR.glob("slide-*.png")) if SLIDES_DIR.exists() else []
    if 0 < slide_num <= len(images):
        return FileResponse(images[slide_num - 1])
    return JSONResponse({"error": "Slide not found"}, status_code=404)


@app.get("/api/audio/{slide_num}")
async def api_audio(slide_num: int):
    audio_path = AUDIO_DIR / f"slide_{slide_num:02d}.wav"
    if audio_path.exists():
        return FileResponse(audio_path, media_type="audio/wav")
    return JSONResponse({"error": "Audio not found"}, status_code=404)


@app.post("/api/update-script/{slide_num}")
async def api_update_script(slide_num: int, text: str = Form(...)):
    if not SCRIPT_PATH.exists():
        return JSONResponse({"error": "No script file"}, status_code=404)

    content = SCRIPT_PATH.read_text()
    slides = _parse_current_script()

    # Rebuild the script with the updated text for this slide
    blocks = content.split("---")
    for i, block in enumerate(blocks):
        import re
        match = re.search(r"##\s+Slide\s+(\d+)", block)
        if match and int(match.group(1)) == slide_num:
            # Keep the heading, replace the body
            heading_line = match.group(0)
            # Find the full heading line
            lines = block.strip().split("\n")
            heading_full = lines[0] if lines else heading_line
            blocks[i] = f"\n{heading_full}\n\n{text}\n"
            break

    SCRIPT_PATH.write_text("---".join(blocks))
    return {"status": "ok"}


@app.post("/api/generate/{slide_num}")
async def api_generate(slide_num: int):
    if engine is None:
        return JSONResponse({"error": "Load TTS engine first"}, status_code=400)
    if voice_wav_path is None:
        return JSONResponse({"error": "Upload voice sample first"}, status_code=400)

    slides = _parse_current_script()
    target = None
    for num, text in slides:
        if num == slide_num:
            target = (num, text)
            break

    if target is None:
        return JSONResponse({"error": f"Slide {slide_num} not found"}, status_code=404)

    num, text = target
    AUDIO_DIR.mkdir(exist_ok=True)
    out_path = AUDIO_DIR / f"slide_{num:02d}.wav"
    if out_path.exists():
        out_path.unlink()

    duration = _generate_slide_audio(text, engine, voice_wav_path, out_path, "en")
    hashes = _load_cache_hashes(AUDIO_DIR / "hashes.json")
    hashes[f"slide_{num:02d}"] = _text_hash(text)
    _save_cache_hashes(AUDIO_DIR / "hashes.json", hashes)

    return {"status": "ok", "duration": round(duration, 1)}


@app.post("/api/generate-all")
async def api_generate_all():
    if engine is None:
        return JSONResponse({"error": "Load TTS engine first"}, status_code=400)
    if voice_wav_path is None:
        return JSONResponse({"error": "Upload voice sample first"}, status_code=400)

    slides = _parse_current_script()
    clips = generate_audio_clips(slides, engine, voice_wav_path, AUDIO_DIR, "en")
    total = sum(sf.info(str(c)).duration for c in clips)
    return {"status": "ok", "total_duration": round(total, 1), "count": len(clips)}


@app.post("/api/build-video")
async def api_build_video(
    pause: float = Form(1.0),
    use_click: bool = Form(True),
):
    if engine is None:
        return JSONResponse({"error": "Load TTS engine first"}, status_code=400)
    if voice_wav_path is None:
        return JSONResponse({"error": "Upload voice sample first"}, status_code=400)

    slides = _parse_current_script()
    clips = generate_audio_clips(slides, engine, voice_wav_path, AUDIO_DIR, "en")
    images = extract_slide_images(Path("presentation.pdf"), SLIDES_DIR)

    click_path = Path("click.wav") if use_click and Path("click.wav").exists() else None
    output = WORK_DIR / "video.mp4"

    assemble_video(
        images, clips, slides, output,
        engine=engine, voice_wav_path=voice_wav_path,
        language="en", pause=pause, click_sound=click_path,
    )

    return {"status": "ok", "video_url": "/api/video"}


@app.get("/api/video")
async def api_video():
    video_path = WORK_DIR / "video.mp4"
    if video_path.exists():
        return FileResponse(video_path, media_type="video/mp4")
    return JSONResponse({"error": "Video not found"}, status_code=404)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
