"""Source contract for MeasureFrameTime (no live game required).

Registration is three separate edits in McpTools.as. Omitting any one leaves a
tool that compiles and cannot be called.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def _mcp_tools() -> str:
    return (SRC / "McpTools.as").read_text()


def _impl() -> str:
    return (SRC / "Readiness.as").read_text()


def clamp_measure_frames(n):
    """Python port of ClampMeasureFrames. Default 10, cap 30."""
    if n is None:
        return 10
    n = int(n)
    if n < 1:
        return 10
    if n > 30:
        return 30
    return n


def clamp_measure_warmup(n):
    """Python port of ClampMeasureWarmup. Default 1, cap 5."""
    if n is None:
        return 1
    n = int(n)
    if n < 0:
        return 0
    if n > 5:
        return 5
    return n


def fps_from_sample(frames, elapsed_ms):
    if elapsed_ms <= 0:
        return 0.0
    return frames * 1000.0 / elapsed_ms


def test_clamp_frames_default_and_cap():
    assert clamp_measure_frames(None) == 10
    assert clamp_measure_frames(0) == 10
    assert clamp_measure_frames(1) == 1
    assert clamp_measure_frames(10) == 10
    assert clamp_measure_frames(30) == 30
    assert clamp_measure_frames(31) == 30


def test_clamp_warmup_default_and_cap():
    assert clamp_measure_warmup(None) == 1
    assert clamp_measure_warmup(-1) == 0
    assert clamp_measure_warmup(0) == 0
    assert clamp_measure_warmup(1) == 1
    assert clamp_measure_warmup(5) == 5
    assert clamp_measure_warmup(6) == 5


def test_ten_frames_at_30fps_cap_is_about_333ms():
    # 10 * (1000/30) = 333.333... ms. User: 0.33s means we are at the cap.
    assert abs(fps_from_sample(10, 333) - 30.03) < 0.1


def test_ten_frames_in_3s_is_a_hitch():
    # User: 10 frames in 3s means the hitch is present.
    assert abs(fps_from_sample(10, 3000) - (10.0 / 3.0)) < 0.01


def test_registered_at_all_three_points():
    text = _mcp_tools()
    assert 'name == "MeasureFrameTime"' in text, "missing from the sync-dispatch allowlist"
    assert 'if (name == "MeasureFrameTime") return MeasureFrameTime(input);' in text, \
        "missing dispatch branch"
    assert 'MakeTool("MeasureFrameTime"' in text, "missing MakeTool registration"


def test_schema_frames_and_warmup():
    line = next(l for l in _mcp_tools().splitlines() if 'MakeTool("MeasureFrameTime"' in l)
    match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
    assert match, "could not extract schema from MakeTool(MeasureFrameTime)"
    schema = json.loads(match.group(1))
    props = schema["properties"]
    assert "frames" in props
    assert props["frames"]["type"] == "integer"
    assert "warmupFrames" in props
    assert schema.get("additionalProperties") is False


def test_impl_yields_and_clamps():
    text = _impl()
    assert "ClampMeasureFrames" in text
    assert "ClampMeasureWarmup" in text
    assert "yield()" in text
    assert "n > 30" in text
    assert "n > 5" in text
    assert '"elapsedMs"' in text
    assert '"msPerFrame"' in text
    assert '"fps"' in text
    assert '"minMs"' in text
    assert '"maxMs"' in text
    assert '"capFps"' in text
