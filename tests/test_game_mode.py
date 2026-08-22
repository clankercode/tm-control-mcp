"""Source contract for GetMode editor-kind detection (no live game required)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def test_detect_editor_kind_mappings():
    text = (SRC / "Readiness.as").read_text()
    expected = {
        "CGameCtnEditorFree": "MapEditor",
        "CGameEditorItem": "ItemEditor",
        "CGameEditorMediaTracker": "MediatrackerEditor",
        "CGameEditorMesh": "MeshEditor",
        "CGameEditorSkin": "SkinEditor",
        "CGameEditorModule": "ModuleEditor",
    }
    for cls, mode in expected.items():
        assert cls in text, cls
        assert f'return "{mode}"' in text, mode
    assert 'return "Editor"' in text
    assert "DetectEditorKindName" in text
    assert "DetectMapEditorModeName" in text
    assert 'return "MapEditor_Validate"' in text
    assert 'return "MapEditor_Test"' in text
    assert 'return "MapEditor_Playground"' in text
    assert "IsEditorModeName" in text
    assert "bool ModeMatches" in text
    assert 'w == "mapeditor" && a.StartsWith("mapeditor")' in text
    assert "DetectGameModeName()" in (SRC / "McpTools.as").read_text()


def test_readiness_treats_editor_as_family():
    text = (SRC / "Readiness.as").read_text()
    assert "modeOk = IsEditorModeName(mode)" in text
    assert "return ModeMatches(mode, equals)" in text
    assert 'if (w == "editor" && IsEditorModeName(actual)) return true' in text


def test_getmode_tool_describes_specific_editors():
    text = (SRC / "McpTools.as").read_text()
    desc_line = next(l for l in text.splitlines() if 'MakeTool("GetMode"' in l)
    for name in (
        "MapEditor",
        "MapEditor_Test",
        "MapEditor_Validate",
        "MapEditor_Playground",
        "ItemEditor",
        "MediatrackerEditor",
        "MeshEditor",
        "SkinEditor",
        "ModuleEditor",
    ):
        assert name in desc_line, name
    assert "equals=Editor matches any editor" in desc_line
    assert "curGameModeStr" in desc_line


def test_getmode_reports_curgamemodestr():
    readiness = (SRC / "Readiness.as").read_text()
    tools = (SRC / "McpTools.as").read_text()
    server = (SRC / "RaceTools.as").read_text()
    assert "string GetCurGameModeStr()" in readiness
    assert "CurGameModeStr" in readiness
    assert "CTrackManiaNetworkServerInfo" in readiness
    start = tools.index("Json::Value@ GetMode(")
    body = tools[start : start + 1200]
    assert 'output["curGameModeStr"]' in body
    assert "GetCurGameModeStr()" in body
    assert 'output["curGameModeStr"]' in server
    assert "GetCurGameModeStr()" in server
