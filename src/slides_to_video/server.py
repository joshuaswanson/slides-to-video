"""FastAPI backend for the slides-to-video editor.

Launch with: uv run slides-to-video-editor --script script.md --slides presentation.pdf
Then open http://localhost:8000 in your browser.
"""

from __future__ import annotations

import argparse
import shutil
import tempfile
import threading
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path

import soundfile as sf
import uvicorn
from fastapi import FastAPI, File, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from .audio import (
    DEFAULT_CLICK, MAX_SPEED, MIN_SPEED, ClipCache, ambient_loop, assemble_track, clip_path,
    ensure_clips, prepare_voice, synthesize_slide,
)
from .script import ScriptError, Slide, parse_script, update_slide_text
from .tools import PipelineError, atomic_write_text
from .tts_engines import ENGINES, LANGUAGES, TTSEngine, check_language, get_engine
from .video import (
    DEFAULT_HEIGHT, assemble_video, extract_slide_images, images_for_slides, slide_image_paths,
)

EDITOR_HTML = Path(__file__).parent / "web" / "editor.html"


@dataclass
class EditorState:
    script_path: Path
    pdf_path: Path | None
    cache_dir: Path
    click_path: Path = DEFAULT_CLICK
    engine_name: str | None = None
    device: str = "cuda"
    language: str = "en"
    pause: float = 1.0
    speed: float = 1.0
    use_click: bool = True
    height: int = DEFAULT_HEIGHT
    engine: TTSEngine | None = None
    gpu_lock: threading.Lock = field(default_factory=threading.Lock)
    script_lock: threading.Lock = field(default_factory=threading.Lock)

    @property
    def audio_dir(self) -> Path:
        return self.cache_dir / "audio_clips"

    @property
    def images_dir(self) -> Path:
        return self.cache_dir / "slide_images"

    @property
    def voice_path(self) -> Path:
        return self.cache_dir / "voice.wav"

    @property
    def voice(self) -> Path | None:
        return self.voice_path if self.voice_path.exists() else None

    def clip_cache(self) -> ClipCache | None:
        if self.engine_name is None:
            return None
        return ClipCache(self.audio_dir, self.engine_name, self.language, self.voice)

    def require_cache(self) -> ClipCache:
        cache = self.clip_cache()
        if cache is None:
            raise PipelineError("Select a TTS engine first (Settings > TTS Engine)")
        return cache

    def slides(self) -> list[Slide]:
        if not self.script_path.exists():
            return []
        return parse_script(self.script_path.read_text())

    def slide(self, num: int) -> Slide:
        for slide in self.slides():
            if slide.num == num:
                return slide
        raise LookupError(f"Slide {num} not found in script")

    def require_generation(self) -> tuple[TTSEngine, Path]:
        self.require_cache()
        if self.engine is None:
            raise PipelineError("Load a TTS engine first (Settings > Load Engine)")
        if self.voice is None:
            raise PipelineError("Upload a voice sample first (Settings > Voice Sample)")
        return self.engine, self.voice

    def render_slides(self) -> list[Path]:
        if self.pdf_path is None:
            return []
        return extract_slide_images(self.pdf_path, self.images_dir, self.height)


class EngineRequest(BaseModel):
    engine: str
    device: str = "cuda"


class SettingsRequest(BaseModel):
    engine: str | None = None
    language: str | None = None
    pause: float | None = Field(default=None, ge=0)
    speed: float | None = Field(default=None, ge=MIN_SPEED, le=MAX_SPEED)
    use_click: bool | None = None


class ScriptUpdate(BaseModel):
    text: str


def _save_upload(upload: UploadFile, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        shutil.copyfileobj(upload.file, tmp)
    Path(tmp.name).replace(path)


def create_app(state: EditorState) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_: FastAPI):
        try:
            state.render_slides()
        except PipelineError as e:
            print(f"Could not render slides: {e}")
        yield

    app = FastAPI(lifespan=lifespan)

    @app.exception_handler(PipelineError)
    @app.exception_handler(ScriptError)
    @app.exception_handler(ValueError)
    async def bad_request(_: Request, exc: Exception):
        return JSONResponse({"error": str(exc)}, status_code=400)

    @app.exception_handler(LookupError)
    async def not_found(_: Request, exc: Exception):
        return JSONResponse({"error": str(exc)}, status_code=404)

    @app.get("/")
    def index():
        return HTMLResponse(EDITOR_HTML.read_text())

    @app.get("/api/config")
    def api_config():
        return {
            "engines": sorted(ENGINES),
            "languages": LANGUAGES,
            "engine": state.engine_name,
            "engine_loaded": state.engine is not None,
            "device": state.device,
            "language": state.language,
            "pause": state.pause,
            "speed": state.speed,
            "use_click": state.use_click,
            "has_voice": state.voice is not None,
            "has_slides": bool(slide_image_paths(state.images_dir)),
            "script_path": str(state.script_path),
        }

    @app.post("/api/settings")
    def api_settings(req: SettingsRequest):
        engine_name = state.engine_name
        if req.engine is not None:
            if req.engine not in ENGINES:
                raise PipelineError(f"Unknown TTS engine {req.engine!r}")
            engine_name = req.engine
        language = req.language if req.language is not None else state.language
        if engine_name is not None:
            check_language(engine_name, language)
        if engine_name != state.engine_name:
            with state.gpu_lock:
                state.engine = None
                state.engine_name = engine_name
        state.language = language
        if req.pause is not None:
            state.pause = req.pause
        if req.speed is not None:
            state.speed = req.speed
        if req.use_click is not None:
            state.use_click = req.use_click
        return api_config()

    @app.post("/api/load-engine")
    def api_load_engine(req: EngineRequest):
        if req.engine not in ENGINES:
            raise PipelineError(f"Unknown TTS engine {req.engine!r}")
        check_language(req.engine, state.language)
        with state.gpu_lock:
            if state.engine is not None and (state.engine_name, state.device) == (req.engine, req.device):
                return {"message": f"Engine '{req.engine}' already loaded."}
            state.engine = None
            engine = get_engine(req.engine)
            engine.load(req.device)
            state.engine, state.engine_name, state.device = engine, req.engine, req.device
        return {"message": f"Loaded '{req.engine}' on {req.device}."}

    @app.post("/api/upload-voice")
    def api_upload_voice(file: UploadFile = File(...)):
        suffix = Path(file.filename or "voice").suffix or ".wav"
        with tempfile.TemporaryDirectory() as tmp:
            upload = Path(tmp) / f"upload{suffix}"
            _save_upload(file, upload)
            prepare_voice([upload], state.voice_path)
        return {"message": "Voice sample ready."}

    @app.post("/api/upload-slides")
    def api_upload_slides(file: UploadFile = File(...)):
        pdf = state.cache_dir / "slides.pdf"
        _save_upload(file, pdf)
        state.pdf_path = pdf
        images = state.render_slides()
        return {"message": f"Loaded {len(images)} slides."}

    @app.get("/api/slides")
    def api_slides():
        cache = state.clip_cache()
        result = []
        for slide in state.slides():
            fresh = cache is not None and cache.is_fresh(slide)
            result.append({
                "slide_num": slide.num,
                "text": slide.text,
                "has_audio": fresh,
                "duration": round(sf.info(str(cache.path(slide.num))).duration, 1) if fresh else 0,
            })
        return result

    def _page(directory: Path, num: int):
        images = slide_image_paths(directory)
        if not 1 <= num <= len(images):
            raise LookupError(f"No image for slide {num}")
        return FileResponse(images[num - 1], media_type="image/png")

    @app.get("/api/slide-image/{slide_num}")
    def api_slide_image(slide_num: int):
        return _page(state.images_dir, slide_num)

    @app.get("/api/slide-thumb/{slide_num}")
    def api_slide_thumb(slide_num: int):
        return _page(state.images_dir / "thumbs", slide_num)

    @app.get("/api/audio/{slide_num}")
    def api_audio(slide_num: int):
        path = clip_path(state.audio_dir, slide_num)
        if not path.exists():
            raise LookupError(f"No audio for slide {slide_num}")
        return FileResponse(path, media_type="audio/wav")

    @app.post("/api/update-script/{slide_num}")
    def api_update_script(slide_num: int, req: ScriptUpdate):
        with state.script_lock:
            if not state.script_path.exists():
                raise LookupError(f"Script file {state.script_path} not found")
            content = update_slide_text(state.script_path.read_text(), slide_num, req.text)
            atomic_write_text(state.script_path, content)
        return {"status": "ok"}

    @app.post("/api/generate/{slide_num}")
    def api_generate(slide_num: int):
        slide = state.slide(slide_num)
        with state.gpu_lock:
            engine, voice = state.require_generation()
            wav, sr = synthesize_slide(slide, engine, voice, state.language)
            state.require_cache().store(slide, wav, sr)
        return {"status": "ok", "duration": round(len(wav) / sr, 1)}

    @app.post("/api/generate-all")
    def api_generate_all():
        slides = state.slides()
        with state.gpu_lock:
            engine, voice = state.require_generation()
            clips = ensure_clips(slides, engine, voice, state.require_cache(), state.language)
        total = sum(sf.info(str(c)).duration for c in clips)
        return {"status": "ok", "total_duration": round(total, 1), "count": len(clips)}

    def _track(clips: list[Path]):
        cache = state.require_cache()
        ambient = ambient_loop(cache, state.engine, state.voice, state.language)
        return assemble_track(
            clips, pause=state.pause, speed=state.speed,
            click_path=state.click_path if state.use_click else None,
            ambient_path=ambient,
        )

    @app.post("/api/build-preview-audio")
    def api_build_preview_audio():
        slides = state.slides()
        cache = state.require_cache()
        stale = [s.num for s in slides if not cache.is_fresh(s)]
        if stale:
            raise PipelineError(f"Slides {stale} have no up-to-date audio. Generate them first.")
        with state.gpu_lock:
            track = _track([cache.path(s.num) for s in slides])
        track.write(state.cache_dir / "preview_audio.wav")
        return {
            "status": "ok",
            "audio_url": "/api/preview-audio",
            "timestamps": [
                {"time": round(t, 3), "slide_num": s.num}
                for s, t in zip(slides, track.slide_starts)
            ],
            "total_duration": round(track.duration, 1),
        }

    @app.get("/api/preview-audio")
    def api_preview_audio():
        path = state.cache_dir / "preview_audio.wav"
        if not path.exists():
            raise LookupError("Preview audio not built yet")
        return FileResponse(path, media_type="audio/wav")

    @app.post("/api/build-video")
    def api_build_video():
        slides = state.slides()
        if not slides:
            raise PipelineError("The script has no slides")
        images = images_for_slides(slides, state.render_slides())
        with state.gpu_lock:
            engine, voice = state.require_generation()
            clips = ensure_clips(slides, engine, voice, state.require_cache(), state.language)
            track = _track(clips)
        assemble_video(images, track, state.cache_dir / "video.mp4", state.height)
        return {"status": "ok", "video_url": "/api/video"}

    @app.get("/api/video")
    def api_video():
        path = state.cache_dir / "video.mp4"
        if not path.exists():
            raise LookupError("Video not built yet")
        return FileResponse(path, media_type="video/mp4")

    return app


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Run the slides-to-video web editor.")
    parser.add_argument("--script", type=Path, default=Path("script.md"), help="Narration script to edit")
    parser.add_argument("--slides", type=Path, default=None, help="Slides PDF (can also be uploaded in the editor)")
    parser.add_argument("--voice", type=Path, nargs="+", default=None, help="Voice sample(s) to clone")
    parser.add_argument("--cache-dir", type=Path, default=Path(".cache"))
    parser.add_argument(
        "--tts-engine", default=None, choices=sorted(ENGINES),
        help="TTS engine. Without it, select one in the editor before generating.",
    )
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--language", default="en", choices=sorted(LANGUAGES))
    parser.add_argument("--click-sound", type=Path, default=DEFAULT_CLICK)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    parser.add_argument(
        "--host", default="127.0.0.1",
        help="Interface to bind. The editor has no authentication, so keep the default "
        "and use an SSH tunnel to reach a remote machine.",
    )
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args(argv)

    state = EditorState(
        script_path=args.script,
        pdf_path=args.slides,
        cache_dir=args.cache_dir,
        click_path=args.click_sound,
        engine_name=args.tts_engine,
        device=args.device,
        language=args.language,
        height=args.height,
    )
    if args.voice:
        prepare_voice(args.voice, state.voice_path)
    uvicorn.run(create_app(state), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
