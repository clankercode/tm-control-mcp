"""Static contract checks for the native MCP catalog seam."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MCP = (ROOT / "src" / "McpTools.as").read_text()
PACKS = (ROOT / "src" / "ToolPacks.as").read_text()
PROTOCOL = (ROOT / "src" / "Protocol.as").read_text()


def test_catalog_uses_call_instance_and_registry_revision():
    assert 'output["instance"] = g_ToolCallInstance;' in MCP
    assert 'output["revision"] = "" + g_ToolRegistryRevision;' in MCP
    assert "uint64 g_ToolRegistryRevision = 1;" in MCP
    assert "g_ToolRegistryRevision++;" in MCP


def test_catalog_route_and_status_metadata_are_native_only():
    assert 'if (route == "catalog")' in PROTOCOL
    assert "BuildToolCatalog()" in PROTOCOL
    assert 'data["catalog"] = ToolCatalogIdentity();' in PROTOCOL
    assert 'catalog["tools"] = tools;' in MCP


def test_warm_reads_reconcile_liveness_and_detach_json():
    sweep = PACKS.index("void SweepDeadPacks()")
    cache = MCP.index("Json::Value@ GetToolListCached()")
    assert "SweepDeadPacks();" in MCP[cache : cache + 700]
    assert "Json::Parse(Json::Write(value))" in MCP
    assert "GetToolList()" in MCP and "CloneJsonValue(GetToolListCached())" in MCP
    assert "if (changed) InvalidateToolList();" in PACKS[sweep : sweep + 500]


def test_catalog_sort_is_explicit_and_legacy_tool_route_survives():
    assert "CompareCanonicalToolNames" in MCP
    assert 'if (route == "tools")' in PROTOCOL
    assert "GetToolList()" in PROTOCOL
