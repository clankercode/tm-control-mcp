"""Source contract for the ShutdownGame confirmation UI."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "src" / "SettingsSocket.as").read_text()
TOOLS = (ROOT / "src" / "McpTools.as").read_text()


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


def test_shutdown_tool_preserves_explicit_confirmation_guard():
    body = _function_body(TOOLS, "Json::Value@ ShutdownGame(")
    assert 'input.HasKey("confirm")' in body
    assert 'bool(input["confirm"])' in body
    assert 'MakeError("shutdown requires confirm:true"' in body
    assert "RequestShutdownGame()" in body


def test_shutdown_dialog_logs_each_player_action_immediately():
    body = _function_body(SETTINGS, "void RenderShutdownDialog()")
    for action in ("Close TM now", "Add +60s", "Cancel shutdown"):
        assert fr'player pressed \"{action}\"' in body

    close = body.index('UI::Button("Close TM now"')
    close_log = body.index('trace("TM Control MCP shutdown UI: player pressed', close)
    close_queue = body.index("startnew(CoroutineFunc(ShutdownGameAfterOneFrame));", close)
    assert close_log < close_queue


def test_close_now_shutdown_is_deferred_by_exactly_one_frame():
    body = _function_body(SETTINGS, "void ShutdownGameAfterOneFrame()")
    assert body.count("yield();") == 1
    assert body.index("yield();") < body.index("Meta::Terminate();")




def test_final_ten_second_countdown_logs_each_integer_second_once():
    assert "int g_ShutdownLastLoggedSecond = -1;" in SETTINGS
    request = _function_body(SETTINGS, "Json::Value@ RequestShutdownGame()")
    assert "g_ShutdownLastLoggedSecond = -1;" in request

    render = _function_body(SETTINGS, "void RenderShutdownDialog()")
    assert "seconds <= 10" in render
    assert "seconds >= 1" in render
    assert "seconds != g_ShutdownLastLoggedSecond" in render
    assert "g_ShutdownLastLoggedSecond = seconds;" in render
    assert 'Trackmania is shutting down in " + seconds + " seconds' in render


def test_final_countdown_log_is_before_dialog_rendering():
    render = _function_body(SETTINGS, "void RenderShutdownDialog()")
    log = render.index("Trackmania is shutting down in")
    window = render.index('UI::Begin("Trackmania shutdown"')
    assert log < window


def test_shutdown_window_always_ends_when_begin_returns_false():
    render = _function_body(SETTINGS, "void RenderShutdownDialog()")
    # A collapsed Begin still owns a window stack entry.
    assert render.rstrip().endswith("}\n    UI::End();\n}")
