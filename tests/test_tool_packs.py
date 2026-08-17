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
    assert "ToolPackBuilder@ SetPackId" in text
    assert "ToolPackBuilder(const string &in id)" in text
    assert "string packId;" in text


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
    assert 'ToolPackBuilder("fixture")' in main
    assert 'TmMcp::CallTool("GetMode"' in main
    assert "UnregisterToolPack" in main


def test_authoring_doc_exists():
    doc = (ROOT / "docs" / "tool-packs.md").read_text()
    assert "ToolPackBuilder" in doc
    assert "packId.FuncName" in doc
    assert "SetPackId" in doc
    assert 'ToolPackBuilder("mypack")' in doc
    assert "ListToolPacks" in doc


def test_register_resolves_custom_pack_id():
    text = (ROOT / "src" / "ToolPacks.as").read_text()
    assert "IsValidPackIdCharset" in text
    assert "string customId = builder.packId.Trim();" in text
    assert "string packId = customId.Length > 0 ? customId : plugin.ID;" in text
    assert "customId.Length > 0 && !IsValidPackIdCharset(packId)" in text
    assert "pack_bad_id" in text
    assert 'id == "core"' in text
    assert "UnregisterOwnedPacks" in text
