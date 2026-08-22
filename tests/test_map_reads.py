"""Source contract: map-summary reads use app.RootMap (same nod in editor and Race)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
MCP_TOOLS = (SRC / "McpTools.as").read_text()
MAP_ENV = (SRC / "MapEnvironment.as").read_text()


def _fn_body(text: str, name: str) -> str:
    needle = f"Json::Value@ {name}("
    start = text.index(needle)
    nxt = text.find("\n    Json::Value@", start + len(needle))
    return text[start:nxt if nxt != -1 else start + 800]


def test_getchallenge_is_rootmap():
    start = MCP_TOOLS.index("CGameCtnChallenge@ GetChallenge()")
    helper = MCP_TOOLS[start : MCP_TOOLS.index("Json::Value@ NeedMap()")]
    assert "return app.RootMap" in helper
    assert "editor.Challenge" not in helper
    assert 'output["mapSource"]' not in MCP_TOOLS


def test_map_summary_reads_use_getchallenge():
    for name in (
        "GetMapInfo",
        "GetItems",
        "GetRecentItems",
        "GetBlocks",
        "GetRecentBlocks",
        "GetWaypoints",
    ):
        body = _fn_body(MCP_TOOLS, name)
        assert "GetChallenge()" in body, name
        assert "NOT_IN_EDITOR" not in body, name
        assert "NeedMap()" in body or "NO_MAP" in body, name


def test_getmapinfo_describes_play_mode():
    desc = next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("GetMapInfo"' in l)
    assert "RootMap" in desc or "Race" in desc


def test_getmapenvironment_uses_getchallenge():
    assert "GetChallenge()" in MAP_ENV
    assert "NeedMap()" in MAP_ENV or "NO_MAP" in MAP_ENV
