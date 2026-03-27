"""FastAPI backend for the slides-to-video editor.

Launch with: uv run src/server.py
Then open http://localhost:8000 in your browser.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure src/ is on the path when running from project root
sys.path.insert(0, str(Path(__file__).parent))

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
    return FileResponse("web/editor.html")


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

    click_path = Path("assets/click.wav") if use_click and Path("assets/click.wav").exists() else None
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


@app.post("/api/build-preview-audio")
async def api_build_preview_audio(pause: float = Form(1.0), use_click: bool = Form(True)):
    """Build a single audio file with all slides + pauses + clicks for preview playback.

    Uses only cached audio clips, no TTS model needed.
    """
    import subprocess
    import tempfile

    slides = _parse_current_script()
    AUDIO_DIR.mkdir(exist_ok=True)

    # Collect cached clips (don't generate, just use what's there)
    clips = []
    for slide_num, text in slides:
        clip = AUDIO_DIR / f"slide_{slide_num:02d}.wav"
        if not clip.exists():
            return JSONResponse(
                {"error": f"Slide {slide_num} has no audio. Generate it first."},
                status_code=400,
            )
        clips.append(clip)

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Use cached ambient noise, or generate silence as fallback
        ambient_path = WORK_DIR / "ambient_cached.wav"
        if not ambient_path.exists():
            subprocess.run(
                ["ffmpeg", "-y", "-f", "lavfi", "-t", str(pause),
                 "-i", "anullsrc=r=24000:cl=mono", "-c:a", "pcm_s16le",
                 str(ambient_path)],
                check=True, capture_output=True,
            )

        # Prepare click sounds
        click_path = Path("assets/click.wav")
        click_down_path = None
        click_up_path = None
        if use_click and click_path.exists():
            click_down_path = tmpdir / "click_down.wav"
            click_up_path = tmpdir / "click_up.wav"
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(click_path),
                 "-t", "0.075", "-ar", "24000", "-ac", "1",
                 "-c:a", "pcm_s16le", str(click_down_path)],
                check=True, capture_output=True,
            )
            subprocess.run(
                ["ffmpeg", "-y", "-i", str(click_path),
                 "-ss", "0.075", "-ar", "24000", "-ac", "1",
                 "-c:a", "pcm_s16le", str(click_up_path)],
                check=True, capture_output=True,
            )

        # Build concat list: for each slide, add pause+clip
        parts = []
        timestamps = []  # (start_time, slide_num) for each slide's narration start
        current_time = 0.0

        for i, (clip, (slide_num, _)) in enumerate(zip(clips, slides)):
            # Pre-pause (with click up if not first slide)
            pre = tmpdir / f"pre_{i}.wav"
            if click_up_path and i > 0:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(ambient_path), "-i", str(click_up_path),
                     "-filter_complex",
                     "[1:a]apad=whole_dur=0[click];[0:a][click]amix=inputs=2:duration=first",
                     "-c:a", "pcm_s16le", str(pre)],
                    check=True, capture_output=True,
                )
            else:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(ambient_path), "-c:a", "pcm_s16le", str(pre)],
                    check=True, capture_output=True,
                )
            parts.append(pre)
            current_time += pause

            timestamps.append({"time": round(current_time, 3), "slide_num": slide_num})
            clip_dur = sf.info(str(clip)).duration
            parts.append(clip)
            current_time += clip_dur

            # Post-pause (with click down if not last)
            post = tmpdir / f"post_{i}.wav"
            is_last = i == len(clips) - 1
            if click_down_path and not is_last:
                click_offset = max(0, pause - 0.075)
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(ambient_path), "-i", str(click_down_path),
                     "-filter_complex",
                     f"[1:a]adelay={int(click_offset*1000)}|{int(click_offset*1000)},apad=whole_dur=0[click];"
                     "[0:a][click]amix=inputs=2:duration=first",
                     "-c:a", "pcm_s16le", str(post)],
                    check=True, capture_output=True,
                )
            else:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(ambient_path), "-c:a", "pcm_s16le", str(post)],
                    check=True, capture_output=True,
                )
            parts.append(post)
            current_time += pause

        # Concatenate all parts - use absolute paths to avoid issues
        concat_file = tmpdir / "concat.txt"
        concat_file.write_text(
            "\n".join(f"file '{p.resolve()}'" for p in parts)
        )
        output = WORK_DIR / "preview_audio.wav"
        result = subprocess.run(
            ["ffmpeg", "-y", "-f", "concat", "-safe", "0",
             "-i", str(concat_file), "-c:a", "pcm_s16le", str(output)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"FFmpeg concat error: {result.stderr}")
            print(f"Concat file contents:\n{concat_file.read_text()[:500]}")

    return {
        "status": "ok",
        "audio_url": "/api/preview-audio",
        "timestamps": timestamps,
        "total_duration": round(current_time, 1),
    }


@app.get("/api/preview-audio")
async def api_preview_audio():
    path = WORK_DIR / "preview_audio.wav"
    if path.exists():
        return FileResponse(path, media_type="audio/wav")
    return JSONResponse({"error": "Preview audio not found"}, status_code=404)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
