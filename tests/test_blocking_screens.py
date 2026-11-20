"""Blocking-screen policy in stock AngelScript + source contracts.

Live evidence (2026-11-17, tmc instance 3, port 30300): Page_PressStart's
button-play-offline reports .Visible==true while its parent frame-play-offline
is hidden — detection must use effective visibility, and label search must not
be part of detection (labels are set by the page script at runtime).
"""
import json
import re
from pathlib import Path
import subprocess

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "BlockingScreensPolicy.as"
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()
PROTOCOL = (ROOT / "src" / "Protocol.as").read_text()
READINESS = (ROOT / "src" / "Readiness.as").read_text()


def run_policy(runner, tmp_path, body):
    case = tmp_path / "blocking_screens_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_classification_truth_table(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    // connErr popup wins over everything (it renders on top of any route)
    Check(ClassifyBlockingScreen(true, true, true, true, true, true, true) == "connection-error", "connErr wins");
    // no pages up
    Check(ClassifyBlockingScreen(false, false, false, false, false, false, false) == "none", "idle menu");
    // PressStart states, most specific first
    Check(ClassifyBlockingScreen(true, true, false, false, false, false, false) == "start-screen", "start prompt");
    Check(ClassifyBlockingScreen(true, false, true, true, false, false, false) == "connection-failed", "offline buttons win over spinner");
    Check(ClassifyBlockingScreen(true, false, false, true, false, false, false) == "connecting", "spinner");
    Check(ClassifyBlockingScreen(true, false, false, false, true, false, false) == "ubi-connect", "ubi connect popup");
    Check(ClassifyBlockingScreen(true, false, false, false, false, true, false) == "welcome-back", "welcome back popup");
    // nothing recognisable visible on the page
    Check(ClassifyBlockingScreen(true, false, false, false, false, false, false) == "none", "pressstart quiet");
    ''')


def test_actions_never_quit(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    string[] actionKinds = {"start-screen", "connection-error", "connection-failed", "ubi-connect", "welcome-back"};
    for (uint i = 0; i < actionKinds.Length; i++) {
        string kind = actionKinds[i];
        Check(BlockingScreenKindNeedsAction(kind), "needs action: " + kind);
        string a = BlockingScreenAutoAction(kind);
        Check(a.Length > 0, "has auto action: " + kind);
        Check(IsValidBlockingScreenAction(a), "auto action is valid: " + kind);
    }
    string[] passive = {"none", "connecting", ""};
    for (uint i = 0; i < passive.Length; i++) {
        Check(!BlockingScreenKindNeedsAction(passive[i]), "no action needed: " + passive[i]);
        Check(BlockingScreenAutoAction(passive[i]) == "", "no auto action: " + passive[i]);
    }
    // The quit button is never a click target of any action.
    string[] actions = {"auto", "start", "confirm", "play-offline", "retry", "later", "quit", ""};
    for (uint i = 0; i < actions.Length; i++) {
        Check(!ActionTargetsControl(actions[i], "button-quit-game"), "quit never targeted by " + actions[i]);
    }
    // Whitelist contents per action.
    Check(ActionTargetsControl("start", "button-start-click"), "start target");
    Check(ActionTargetsControl("confirm", "trackmania-pop-up-multi-choice_button-first-choice"), "confirm target");
    Check(ActionTargetsControl("play-offline", "button-play-offline"), "offline target");
    Check(ActionTargetsControl("play-offline", "button-ubi-connect-offline"), "ubi offline target");
    Check(ActionTargetsControl("retry", "button-back"), "retry target");
    Check(ActionTargetsControl("later", "button-welcome-back-later"), "later target");
    // Unknown action strings target nothing.
    Check(!ActionTargetsControl("quit", "button-back"), "quit action not whitelisted");
    Check(!ActionTargetsControl("anything", "button-start-click"), "unknown action");
    ''')


def test_translation_marker_stripping(as_runner, tmp_path):
    # Markers are the UTF-8 two-byte sequences C2 91 / C2 92 in AngelScript
    # strings, matching _StripTranslationPrefix's observed forms.
    run_policy(as_runner, tmp_path, r'''
    Check(StripTranslationMarkers("\xC2\x92|PressStart|Start") == "Start", "keyed lookup");
    Check(StripTranslationMarkers("\xC2\x92Play offline") == "Play offline", "direct text");
    Check(StripTranslationMarkers("\xC2\x91$<$FA0fallback\xC2\x91\xC2\x92|Online Services Status|Maintenance\xC2\x91tail") == "Maintenance", "fallback then keyed");
    Check(StripTranslationMarkers("|Connection|Stay offline") == "Stay offline", "context only");
    Check(StripTranslationMarkers("|Unterminated") == "|Unterminated", "lone bar kept");
    Check(StripTranslationMarkers("|") == "|", "single bar kept");
    Check(StripTranslationMarkers("") == "", "empty");
    Check(StripTranslationMarkers("plain") == "plain", "plain text");
    ''')


def test_online_services_status_normalization(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(NormalizeOnlineServicesStatus("") == "none", "empty is none");
    Check(NormalizeOnlineServicesStatus("   ") == "none", "blank is none");
    Check(NormalizeOnlineServicesStatus("\xC2\x92|Online Services Status|Maintenance") == "maintenance", "maintenance");
    Check(NormalizeOnlineServicesStatus("Planned maintenance 8:00 PM") == "maintenance", "maintenance words");
    Check(NormalizeOnlineServicesStatus("disruption somewhere") == "disruption", "disruption");
    Check(NormalizeOnlineServicesStatus("No issues detected") == "none", "no issues");
    Check(NormalizeOnlineServicesStatus("something else") == "unknown", "unknown text");
    ''')


def test_registered_at_all_three_points():
    for name, fn in (("GetBlockingScreen", "GetBlockingScreen"), ("DismissBlockingScreen", "DismissBlockingScreen")):
        assert f'name == "{name}"' in MCP_TOOLS, f"{name} missing from IsToolName"
        assert f'if (name == "{name}") return {fn}(input);' in MCP_TOOLS, f"{name} missing dispatch"
        assert f'MakeTool("{name}"' in MCP_TOOLS, f"{name} missing MakeTool registration"


def test_dismiss_observes_dialog_after():
    assert '|| name == "DismissBlockingScreen"' in PROTOCOL


def test_readiness_reports_blocking_screens():
    assert "BuildBlockingScreenSnapshot()" in READINESS
    assert '"menuBlockingScreen"' in READINESS
    # want=any must not soft-override a blocking screen into readiness
    assert "dialogClear && menuBlockingScreen.Length == 0" in READINESS
    # new WaitUntil conditions are accepted and hinted
    assert 'cond == "menureached"' in READINESS
    assert 'cond == "blockingscreen"' in READINESS
    assert "menuReached|blockingScreen" in READINESS


def test_schema():
    for name, required in (("GetBlockingScreen", None), ("DismissBlockingScreen", None)):
        line = next(l for l in MCP_TOOLS.splitlines() if f'MakeTool("{name}"' in l)
        match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
        assert match, f"could not extract schema for {name}"
        schema = json.loads(match.group(1))
        assert schema["type"] == "object"
        if name == "DismissBlockingScreen":
            props = schema["properties"]
            assert set(props) == {"action", "waitMs"}
            assert schema.get("additionalProperties") is False
