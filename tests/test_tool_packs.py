"""Static checks for MCP tool-pack infrastructure."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_shared_export_listed():
    toml = (ROOT / "info.toml").read_text()
    assert "ToolPackShared.as" in toml
    assert (ROOT / "src" / "ToolPackShared.as").is_file()
    assert (ROOT / "src" / "ToolPacks.as").is_file()


def test_shared_types_are_shared():
    text = (ROOT / "src" / "ToolPackShared.as").read_text()
    assert "shared funcdef Json::Value@ ToolPackDispatch" in text
    assert "shared class ToolPackBuilder" in text
    assert "shared class ToolPackTool" in text


def test_exports_include_register():
    text = (ROOT / "src" / "TmMcp_Export.as").read_text()
    assert "RegisterToolPack" in text
    assert "UnregisterToolPack" in text
    assert "ListToolPacks" in text


def test_fixture_pack_exists():
    fix = ROOT / "tools" / "fixtures" / "tm-mcp-pack-fixture"
    assert (fix / "info.toml").is_file()
    assert (fix / "Main.as").is_file()
    info = (fix / "info.toml").read_text()
    assert 'dependencies = ["tm-control-mcp"]' in info
    main = (fix / "Main.as").read_text()
    assert "AddTool(\"Ping\"" in main
    assert "AddTool(\"Echo\"" in main
    assert "AddTool(\"GetMode\"" in main
    assert 'TmMcp::CallTool("GetMode"' in main
    assert "UnregisterToolPack" in main


def test_authoring_doc_exists():
    doc = (ROOT / "docs" / "tool-packs.md").read_text()
    assert "ToolPackBuilder" in doc
    assert "packId.FuncName" in doc
    assert "ListToolPacks" in doc
