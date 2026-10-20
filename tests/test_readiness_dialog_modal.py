"""Readiness must treat known modal frames as blocking even when BasicDialogs is None."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "src" / "Readiness.as").read_text()


def _body(signature: str) -> str:
    start = SRC.index(signature)
    brace = SRC.index("{", start)
    depth = 0
    for i in range(brace, len(SRC)):
        if SRC[i] == "{":
            depth += 1
        elif SRC[i] == "}":
            depth -= 1
            if depth == 0:
                return SRC[start : i + 1]
    raise AssertionError("unterminated function")


def test_frame_modal_blocks_when_basic_dialog_is_none():
    body = _body("bool DialogIsBlocking(")
    assert 'kind != "none"' in body
    assert 'bool(dialog["hasFrame"])' in body
    assert 'frame == "FrameAskYesNo"' in body
    assert 'frame.StartsWith("FrameDialog")' in body
