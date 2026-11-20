"""testFromStart/testFromCoord report a playground that never started.

Live case (2026-11-15): after requestLeavePlayground, further testFromCoord
calls left isTesting true and isSwitchedToPlayground false for 30-60s, then
fell back; the tool had already returned success.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def _body(signature):
    start = MCP_TOOLS.index(signature)
    brace = MCP_TOOLS.index("{", start)
    depth = 0
    for i in range(brace, len(MCP_TOOLS)):
        depth += {"{": 1, "}": -1}.get(MCP_TOOLS[i], 0)
        if depth == 0:
            return MCP_TOOLS[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


BODY = _body("Json::Value@ ControlValidation(")


def test_test_starts_wait_for_the_playground_and_fail_otherwise():
    gate = BODY.index('(action == "testFromStart" || action == "testFromCoord") && waitMs > 0')
    wait = BODY[gate:]
    assert 'input["waitMs"]) : 10000' in BODY
    assert "Math::Min(waitMs, 30000)" in wait
    # No editor handle is held across the frames we wait.
    assert wait.index("@pmt = null;") < wait.index("yield();")
    assert wait.index("@editor = null;") < wait.index("yield();")
    assert "_TestPlaygroundState()" in wait
    assert 'output["playgroundStarted"] = outcome == "started";' in wait
    assert '"PLAYGROUND_NOT_STARTED"' in wait
    assert '"DIALOG_BLOCKING"' in wait
    assert 'err["output"] = output;' in wait
    # Success is only returned after the wait.
    assert BODY.rindex("return MakeSuccess(output);") > wait.index("return err;") + gate


def test_playground_probe_is_single_frame():
    probe = _body("string _TestPlaygroundState(")
    assert "yield" not in probe
    assert "IsSwitchedToPlayground" in probe
    assert "_DialogBlocksNow()" in probe


def test_schema_and_description_expose_the_wait():
    line = next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("ControlValidation"' in l)
    assert '"waitMs":{"type":"integer"}' in line
    assert "PLAYGROUND_NOT_STARTED" in line
    assert "DIALOG_BLOCKING" in line
