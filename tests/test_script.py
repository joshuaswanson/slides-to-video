from pathlib import Path

import pytest

from slides_to_video.script import (
    ScriptError, Slide, parse_script, parse_slide_range, split_pauses, strip_pauses,
    update_slide_text,
)

from .conftest import SCRIPT

EXAMPLE = Path(__file__).parent.parent / "examples" / "example_script.md"


def test_parse_keeps_paragraphs_and_skips_headings():
    slides = parse_script(SCRIPT)
    assert [s.num for s in slides] == [1, 2, 3]
    assert slides[1].text == (
        "First paragraph line one\ncontinues here.\n\n"
        "Second paragraph [pause 0.2] after a pause."
    )
    assert slides[1].narration == (
        "First paragraph line one continues here. "
        "Second paragraph [pause 0.2] after a pause."
    )


def test_parse_includes_slides_without_narration():
    slides = parse_script("## Slide 1\n\n---\n\n## Slide 2\n\nText\n")
    assert slides == [Slide(1, ""), Slide(2, "Text")]


def test_parse_rejects_duplicate_slide_numbers():
    with pytest.raises(ScriptError):
        parse_script("## Slide 1\n\nA\n\n---\n\n## Slide 1\n\nB\n")


def test_triple_dash_inside_a_line_is_not_a_separator():
    slides = parse_script("## Slide 1\n\nBefore --- after\n")
    assert slides[0].text == "Before --- after"


@pytest.mark.parametrize("content", [SCRIPT, EXAMPLE.read_text()])
def test_update_with_same_text_is_identity(content):
    for slide in parse_script(content):
        assert update_slide_text(content, slide.num, slide.text) == content


def test_update_changes_only_target_slide():
    updated = update_slide_text(SCRIPT, 2, "New text.\n\nSecond paragraph.")
    before, after = parse_script(SCRIPT), parse_script(updated)
    assert after[1].text == "New text.\n\nSecond paragraph."
    assert after[0] == before[0] and after[2] == before[2]
    assert "## Slide 2 - Middle" in updated


def test_update_to_empty_and_back():
    emptied = update_slide_text(SCRIPT, 3, "")
    assert parse_script(emptied)[2].text == ""
    restored = update_slide_text(emptied, 3, "Goodbye.")
    assert parse_script(restored) == parse_script(SCRIPT)


@pytest.mark.parametrize("text", ["a\n---\nb", "# not narration"])
def test_update_rejects_text_that_would_change_structure(text):
    with pytest.raises(ScriptError):
        update_slide_text(SCRIPT, 1, text)


def test_update_unknown_slide():
    with pytest.raises(ScriptError):
        update_slide_text(SCRIPT, 9, "x")


def test_split_pauses():
    assert split_pauses("[pause] Hi [pause 1.5] there [pause .25]") == [0.5, "Hi", 1.5, "there", 0.25]
    assert split_pauses("No pauses") == ["No pauses"]
    assert split_pauses("") == []


def test_strip_pauses():
    assert strip_pauses("A [pause] B [pause 2]  C") == "A B C"


def test_parse_slide_range():
    assert parse_slide_range("1,3,5-7") == {1, 3, 5, 6, 7}
    assert parse_slide_range(" 2 , 4-4 ") == {2, 4}
    for bad in ["x", "3-1", "1-"]:
        with pytest.raises(ScriptError):
            parse_slide_range(bad)
