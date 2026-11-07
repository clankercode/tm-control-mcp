"""Validation warnings must carry the full visible editor message state."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_validation_attaches_warning_after_yield_and_keeps_status_observable():
    text = (ROOT / "src/McpTools.as").read_text()
    body = text[text.index("Json::Value@ ControlValidation("):text.index("Json::Value@ ControlSelection(")]
    assert body.index("yield();") < body.index("AttachValidationWarning(output)")
    helper = text[text.index("void AttachValidationWarning("):text.index("Json::Value@ ControlValidation(")]
    assert "BuildDialogSummary()" in helper
    assert 'output["dialogAfter"]' in helper
    assert 'output["warning"]' in helper
    assert "RespondDialog" in helper
    assert 'summary["tempMessage"]' in helper
    assert "_LeaveDialogIsUp()" in helper
    assert '_IsLeaveBlockingFrameName(string(frames[i]["idName"]))' in helper
    assert 'bool(frames[i]["visible"])' in helper


def test_editor_temp_message_ignores_hidden_stale_label():
    text = (ROOT / "src/McpTools.as").read_text()
    body = text[text.index("string _GetEditorTempMessage("):text.index("Json::Value@ GetMenuFrameTree(")]
    assert "!frame.IsVisible" in body


def test_public_protocol_derives_warning_from_its_final_snapshot():
    protocol = (ROOT / "src/Protocol.as").read_text()
    body = protocol[protocol.index("void AttachDialogAfterTool("):protocol.index("Json::Value@ HandlePayload(")]
    assert body.index("yield();") < body.index('name == "ControlValidation"')
    assert "AttachValidationWarning(output);" in body
    helper = (ROOT / "src/McpTools.as").read_text()
    helper = helper[helper.index("void AttachValidationWarning("):helper.index("Json::Value@ ControlValidation(")]
    assert 'output["warning"] = "";' in helper
