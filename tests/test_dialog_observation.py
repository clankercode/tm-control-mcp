"""Public response contract for actions that can surface Trackmania dialogs."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = (ROOT / "src" / "Protocol.as").read_text()
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


DIALOG_OBSERVED_TOOLS = {
    "OpenMapInEditor",
    "PlayMap",
    "ComputeShadows",
    "SaveMapAs",
    "SaveMapFlow",
    "RespondDialog",
    "ControlValidation",
    "TriggerEditorControl",
    "SetMenuPage",
    "EditNewMap",
    "BackToMainMenu",
    "ClickMenuButton",
    "TriggerControlOnAction",
    "CreateMapViaMenu",
    "RunManialinkScript",
}


def _function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    raise AssertionError(f"unterminated function: {signature}")


def test_dialog_prone_tool_set_is_explicit_and_bounded():
    body = _function_body(PROTOCOL, "bool ShouldObserveDialogAfterTool(")
    observed = {
        name for name in DIALOG_OBSERVED_TOOLS if f'name == "{name}"' in body
    }
    assert observed == DIALOG_OBSERVED_TOOLS
    assert 'name == "GetDialog"' not in body
    assert 'name == "WaitUntil"' not in body
    assert 'name == "GetResult"' not in body


def test_public_success_response_yields_then_attaches_full_dialog_state():
    body = _function_body(PROTOCOL, "void AttachDialogAfterTool(")
    assert 'result.HasKey("success")' in body
    assert 'result.HasKey("output")' in body
    yield_at = body.index("yield();")
    snapshot_at = body.index("BuildDialogSummary()")
    assert yield_at < snapshot_at
    assert 'output["dialogAfter"]' in body
    assert 'output["dialogAfterFrameDelay"] = 1' in body

    handle_call = _function_body(PROTOCOL, "Json::Value@ HandleCall(")
    assert "AttachDialogAfterTool(tool, result);" in handle_call


def test_get_dialog_and_automatic_observation_share_one_snapshot_builder():
    builder = _function_body(MCP_TOOLS, "Json::Value BuildDialogSummary(")
    for field in ("editorFrames", "tempMessage", "activeMenus"):
        assert f'summary["{field}"]' in builder

    get_dialog = _function_body(MCP_TOOLS, "Json::Value@ GetDialog(")
    assert "return MakeSuccess(BuildDialogSummary());" in get_dialog


def test_runtime_tool_metadata_promises_dialog_after_only_for_bounded_set():
    make_tool = _function_body(MCP_TOOLS, "Json::Value MakeTool(")
    assert "ShouldObserveDialogAfterTool(name)" in make_tool
    assert "dialogAfter" in make_tool
    assert "successful public socket calls" in make_tool


def test_readme_documents_presence_and_scope():
    readme = (ROOT / "README.md").read_text()
    assert "dialogAfter" in readme
    assert "dialogAfterFrameDelay" in readme
    assert "one rendered frame" in readme
