import base64
import io
import json
import subprocess
import sys

import numpy as np

from slides_to_video.worker import Worker, serve

from .conftest import SR


def decode(reply):
    return np.frombuffer(base64.b64decode(reply["pcm16_b64"]), dtype="<i2")


def run(worker, *requests):
    out = io.StringIO()
    serve(io.StringIO("".join(json.dumps(r) + "\n" for r in requests)), out, worker)
    return [json.loads(line) for line in out.getvalue().splitlines()]


def test_full_session(fake_engine, voice_wav):
    voice = base64.b64encode(voice_wav.read_bytes()).decode()
    replies = run(
        Worker(),
        {"id": 1, "cmd": "hello"},
        {"id": 2, "cmd": "load", "engine": "fake", "device": "cpu"},
        {"id": 3, "cmd": "set_voice", "wav_b64": voice},
        {"id": 4, "cmd": "synthesize", "text": "one two [pause 0.5] three", "language": "en"},
        {"id": 5, "cmd": "ambient", "language": "en"},
    )
    assert [r["id"] for r in replies] == [1, 2, 3, 4, 5]
    assert all(r["ok"] for r in replies), replies
    assert "fake" in replies[0]["engines"] and "cpu" in replies[0]["devices"]
    assert len(replies[2]["voice_hash"]) == 16
    speech = decode(replies[3])
    assert replies[3]["sample_rate"] == SR
    assert len(speech) == 3 * int(0.1 * SR) + int(0.5 * SR)
    assert 0 < len(decode(replies[4])) < SR


def test_errors_are_replies(fake_engine):
    replies = run(
        Worker(),
        {"id": 1, "cmd": "synthesize", "text": "hi"},
        {"id": 2, "cmd": "nope"},
        {"id": 3, "cmd": "load", "engine": "missing"},
    )
    assert [r["ok"] for r in replies] == [False, False, False]
    assert "No engine loaded" in replies[0]["error"]
    assert "Unknown command" in replies[1]["error"]
    assert "missing" in replies[2]["error"]


def test_bad_json_does_not_stop_the_worker():
    out = io.StringIO()
    serve(io.StringIO("not json\n" + json.dumps({"id": 7, "cmd": "hello"}) + "\n"), out)
    replies = [json.loads(line) for line in out.getvalue().splitlines()]
    assert replies[0]["ok"] is False and replies[0]["id"] is None
    assert replies[1]["ok"] and replies[1]["id"] == 7


def test_stdout_carries_only_protocol_lines():
    script = (
        "import sys; from slides_to_video import worker;"
        "orig = worker.Worker.cmd_hello;"
        "worker.Worker.cmd_hello = lambda self, r: (print('library noise'), orig(self, r))[1];"
        "worker.main()"
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        input=json.dumps({"id": 1, "cmd": "hello"}) + "\n",
        capture_output=True, text=True, timeout=60,
    )
    lines = result.stdout.splitlines()
    assert len(lines) == 1 and json.loads(lines[0])["ok"]
    assert "library noise" in result.stderr and "ready" in result.stderr
