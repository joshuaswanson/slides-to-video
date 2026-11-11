"""Write the fixture that checks the Swift port against slides_to_video.script and tools.

Run from the repo root: uv run macos/scripts/make_parity_fixture.py
"""

import json
from pathlib import Path

from slides_to_video.script import ScriptError, parse_script, split_pauses, strip_pauses, update_slide_text
from slides_to_video.audio import ClipCache
from slides_to_video.script import Slide
from slides_to_video.tools import file_hash, text_hash

FIXTURES = Path(__file__).parent.parent / "Tests" / "SlidesToVideoKitTests" / "Fixtures"

SCRIPTS = [
    (FIXTURES / "example_script.md").read_text(),
    "# Talk\n\n---\n\n## Slide 1 - Title\n\nHello there.\n\n---\n\n## Slide 2\n\nLine one\ncontinues.\n\n\nSecond [pause 0.2] para.\n\n---\n\n## Slide 3\n",
    "## Slide 1\n  indented line  \n\tand a tab\n---   \n## Slide 2 - x\n# extra heading\nText --- with dashes\n",
    "No slides here\n---\nnor here\n",
    "## Slide 7\n\nOnly one.",
]
UPDATES = [
    (1, 2, "New text.\n\nSecond paragraph."),
    (1, 3, "Filled in."),
    (1, 1, ""),
    (2, 2, "  spaced  \n\n\n\nout  "),
    (4, 7, "Replaced."),
    (1, 2, "a\n---\nb"),
    (1, 9, "missing"),
]
PAUSES = ["[pause] Hi [pause 1.5] there [pause .25]", "No pauses", "", "A [pause]B[pause 2]  C", "[pause 3]"]
HASHES = [["qwen3", "en", "abcdef0123456789"], ["x"], ["", "", ""], ["Grüße", "日本語"]]


def parsed(content):
    return [{"num": s.num, "text": s.text, "narration": s.narration} for s in parse_script(content)]


def updated(content, num, text):
    try:
        return {"result": update_slide_text(content, num, text)}
    except ScriptError as e:
        return {"error": str(e)}


VOICE = FIXTURES / "voice.wav"
if not VOICE.exists():
    import numpy as np
    import soundfile as sf
    t = np.arange(2400) / 24000
    sf.write(str(VOICE), (0.2 * np.sin(2 * np.pi * 180 * t)).astype(np.float32), 24000)
cache = ClipCache(Path("/nonexistent"), "qwen3", "de", VOICE)
slide = Slide(3, "Hallo  Welt.\n\nZweiter Absatz.")

fixture = {
    "scripts": [{"content": c, "slides": parsed(c)} for c in SCRIPTS],
    "updates": [{"script": i, "slide": n, "text": t, **updated(SCRIPTS[i], n, t)} for i, n, t in UPDATES],
    "pauses": [{"text": t, "items": split_pauses(t), "stripped": strip_pauses(t)} for t in PAUSES],
    "hashes": [{"parts": p, "hash": text_hash(*p)} for p in HASHES],
    "clip_cache": {
        "engine": "qwen3", "language": "de", "voice_hash": file_hash(VOICE),
        "settings_key": cache.settings_key, "slide_text": slide.text, "slide_key": cache._key(slide),
        "ambient_name": cache.ambient_path.name,
    },
}
(FIXTURES / "parity.json").write_text(json.dumps(fixture, indent=2, ensure_ascii=False))
print(f"wrote {FIXTURES / 'parity.json'}")
