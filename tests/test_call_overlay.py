"""Call overlay hide list: pure helpers in stock AngelScript, plus source
contracts for the game side (setting default, header count, no row for
hidden calls on admission or on finish).

Live check: the presentations pack re-records a take with the director's
own polling hidden.
"""
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "CallOverlayPolicy.as"
OVERLAY = (ROOT / "src" / "CallOverlay.as").read_text()


def run_policy(runner, tmp_path, body):
    case = tmp_path / "call_overlay_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_hide_list_parsing(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    auto a = CallOverlayParseHideList("Present.Events,Present.Heartbeat");
    Check(a.Length == 2 && a[0] == "Present.Events" && a[1] == "Present.Heartbeat", "default");
    auto b = CallOverlayParseHideList(" Present.Events , ,Present.Heartbeat,");
    Check(b.Length == 2 && b[0] == "Present.Events" && b[1] == "Present.Heartbeat", "trims, drops empties");
    Check(CallOverlayParseHideList("").Length == 0, "empty hides nothing");
    Check(CallOverlayParseHideList(" , ").Length == 0, "only separators");
    Check(CallOverlayParseHideList("A,A").Length == 1, "deduplicated");
    auto c = CallOverlayParseHideList("present.events");
    Check(c.Find("Present.Events") < 0, "exact, case-sensitive like tool names");
    ''')


def test_header_text(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(CallOverlayHeaderText(766, 512) == "MCP tools: 766 (512 hidden)", "with hidden");
    Check(CallOverlayHeaderText(12, 0) == "MCP tools: 12", "none hidden");
    ''')


def test_setting_default_and_dev_only():
    dev = OVERLAY[OVERLAY.index("#if DEV"):OVERLAY.index("#endif")]
    assert 'string S_TmMcpCallOverlayHide = "Present.Events,Present.Heartbeat";' in dev


def test_hidden_calls_count_but_get_no_row():
    begin = OVERLAY[OVERLAY.index("void CallOverlayBegin"):OVERLAY.index("void CallOverlayFinish")]
    assert begin.index("g_callOverlayCalls++") < begin.index("if (hidden) return;")
    assert "g_callOverlayHidden++" in begin
    assert begin.index("CallOverlayUpdateHeader()") < begin.index("if (hidden) return;"), "header counts hidden calls"
    finish = OVERLAY[OVERLAY.index("void CallOverlayFinish"):OVERLAY.index("void RenderCallOverlay()")]
    assert finish.index("if (CallOverlayHidden(name)) return;") < finish.index("CallOverlayPushRow(row)"), \
        "a finishing hidden call must not recreate a row"


def test_hide_list_parsed_on_change_not_per_call():
    hidden = OVERLAY[OVERLAY.index("bool CallOverlayHidden"):OVERLAY.index("void CallOverlayUpdateHeader")]
    assert "S_TmMcpCallOverlayHide != g_callOverlayHideRaw" in hidden
