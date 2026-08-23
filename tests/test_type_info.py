"""Source contract for GetTypeInfo (no live game required).

Registration in this repo is three separate edits in McpTools.as (the
sync-dispatch allowlist, the dispatch branch, and the MakeTool entry).
Omitting any one of them leaves a tool that compiles and cannot be called.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def _mcp_tools() -> str:
    return (SRC / "McpTools.as").read_text()


def _impl() -> str:
    return (SRC / "ReflectionTools.as").read_text()


def test_get_type_info_is_registered_at_all_three_points():
    text = _mcp_tools()
    assert 'name == "GetTypeInfo"' in text, "missing from the sync-dispatch allowlist"
    assert 'if (name == "GetTypeInfo") return GetTypeInfo(input);' in text, \
        "missing dispatch branch"
    assert 'MakeTool("GetTypeInfo"' in text, "missing MakeTool registration"


def test_get_type_info_is_not_dev_only():
    """Type metadata is read-only; it must ship in release builds."""
    text = _mcp_tools()
    allow = text.split("bool IsToolName", 1)[1].split("bool IsMovedEppTool", 1)[0] \
        if "bool IsMovedEppTool" in text.split("bool IsToolName", 1)[1] else \
        text.split("bool IsToolName", 1)[1]
    # The allowlist entry must sit outside the DEV ifdef that wraps DevSafeRead.
    idx = text.index('name == "GetTypeInfo"')
    dev_block = text.find("#if DEV")
    dev_end = text.find("#endif", dev_block) if dev_block >= 0 else -1
    if dev_block >= 0 and dev_end > dev_block:
        assert not (dev_block < idx < dev_end), \
            "GetTypeInfo must not be registered only under #if DEV"


def test_default_description_promises_class_plus_all_members():
    text = _mcp_tools()
    line = next(l for l in text.splitlines() if 'MakeTool("GetTypeInfo"' in l)
    lower = line.lower()
    assert "classname" in lower
    assert "member" in lower
    assert "all" in lower or "every" in lower


def test_schema_accepts_classname_without_other_required_fields():
    text = _mcp_tools()
    line = next(l for l in text.splitlines() if 'MakeTool("GetTypeInfo"' in l)
    assert '"className"' in line
    assert '"required"' not in line.split("input_schema")[0] or \
        '"required":[]' in line or '"required"' not in line
    # Default call is {className}; schema must not require member/from/classId.
    assert '"required":["className"]' not in line
    assert '"required":["member"]' not in line


def test_impl_uses_live_openplanet_reflection():
    text = _impl()
    assert "Reflection::GetType" in text
    assert "Reflection::TypeOf" in text
    assert ".Members" in text
    assert "GetMember" in text
    assert "BaseType" in text


def test_impl_documents_missing_member_types():
    """Openplanet MwMemberInfo has no type-name field; callers must be told."""
    text = _impl()
    assert "no member type" in text.lower() or "type name" in text.lower()


def test_impl_errors_on_unknown_class_and_missing_lookup():
    text = _impl()
    assert "UNKNOWN_TYPE" in text
    assert "MISSING_LOOKUP" in text


def test_impl_supports_own_only_query_limit_and_single_member():
    text = _impl()
    assert "ownOnly" in text
    assert 'input.HasKey("member")' in text or 'HasKey("member")' in text
    assert 'input.HasKey("query")' in text or 'HasKey("query")' in text
    assert 'input.HasKey("limit")' in text or 'HasKey("limit")' in text
    assert '"declaredOn"' in text
    assert '"isField"' in text
