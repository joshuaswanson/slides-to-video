"""Read and edit narration scripts.

A script is markdown with slide sections separated by lines containing only '---':

    ## Slide 1 - Title
    Text to narrate for slide 1.

    ---

    ## Slide 2 - Introduction
    Text to narrate for slide 2. Use [pause] or [pause 1.5] for silence.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

SEPARATOR_RE = re.compile(r"^---[ \t]*$", re.MULTILINE)
SLIDE_HEADING_RE = re.compile(r"^##\s+Slide\s+(\d+)", re.MULTILINE)
PAUSE_RE = re.compile(r"\[pause(?:\s+(\d+(?:\.\d+)?|\.\d+))?\]")
DEFAULT_INLINE_PAUSE = 0.5


class ScriptError(ValueError):
    pass


@dataclass
class Slide:
    num: int
    text: str

    @property
    def narration(self) -> str:
        """The text sent to TTS, with paragraphs joined into one line."""
        return " ".join(self.text.split())


def _paragraphs(lines: list[str]) -> str:
    paragraphs, current = [], []
    for line in lines:
        if line.strip():
            current.append(line.strip())
        elif current:
            paragraphs.append("\n".join(current))
            current = []
    if current:
        paragraphs.append("\n".join(current))
    return "\n\n".join(paragraphs)


def parse_script(content: str) -> list[Slide]:
    slides = []
    seen = set()
    for block in SEPARATOR_RE.split(content):
        heading = SLIDE_HEADING_RE.search(block)
        if not heading:
            continue
        num = int(heading.group(1))
        if num in seen:
            raise ScriptError(f"Slide {num} appears more than once in the script")
        seen.add(num)
        body = [line for line in block.splitlines() if not line.lstrip().startswith("#")]
        slides.append(Slide(num, _paragraphs(body)))
    return slides


def _validate_text(text: str) -> str:
    text = text.strip()
    for line in text.splitlines():
        if SEPARATOR_RE.fullmatch(line):
            raise ScriptError("Narration cannot contain a line with only '---'")
        if line.lstrip().startswith("#"):
            raise ScriptError("Narration lines cannot start with '#'")
    return _paragraphs(text.splitlines())


def update_slide_text(content: str, slide_num: int, text: str) -> str:
    """Return the script content with the narration of one slide replaced.

    Heading lines of the slide and every other slide are kept byte for byte.
    """
    text = _validate_text(text)
    parts = re.split(r"(^---[ \t]*$)", content, flags=re.MULTILINE)
    for i in range(0, len(parts), 2):
        heading = SLIDE_HEADING_RE.search(parts[i])
        if heading and int(heading.group(1)) == slide_num:
            heading_lines = [
                line for line in parts[i].splitlines() if line.lstrip().startswith("#")
            ]
            body = "\n".join(heading_lines) + ("\n\n" + text if text else "")
            block = parts[i]
            leading = block[: len(block) - len(block.lstrip())]
            trailing = block[len(block.rstrip()):]
            parts[i] = leading + body + trailing
            return "".join(parts)
    raise ScriptError(f"Slide {slide_num} not found in script")


def split_pauses(text: str) -> list[str | float]:
    """Split narration into text segments and pause durations in seconds."""
    items: list[str | float] = []
    pieces = PAUSE_RE.split(text)
    for i, piece in enumerate(pieces):
        if i % 2 == 0:
            if piece.strip():
                items.append(piece.strip())
        else:
            items.append(float(piece) if piece else DEFAULT_INLINE_PAUSE)
    return items


def strip_pauses(text: str) -> str:
    return " ".join(PAUSE_RE.sub(" ", text).split())


def parse_slide_range(spec: str) -> set[int]:
    """Parse a range like '1,3,5-7' into a set of slide numbers."""
    result = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            if "-" in part:
                start, end = (int(x) for x in part.split("-", 1))
                if start > end:
                    raise ValueError
                result.update(range(start, end + 1))
            else:
                result.add(int(part))
        except ValueError:
            raise ScriptError(f"Invalid slide range {part!r}") from None
    return result
