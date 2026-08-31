"""Source contract for ControlFids (no live game required).

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
    return (SRC / "FidsTools.as").read_text()


def _guides() -> str:
    return (SRC / "Guides.as").read_text()


def test_control_fids_is_registered_at_all_three_points():
    text = _mcp_tools()
    assert 'name == "ControlFids"' in text, "missing from the sync-dispatch allowlist"
    assert 'if (name == "ControlFids") return ControlFids(input);' in text, \
        "missing dispatch branch"
    assert 'MakeTool("ControlFids"' in text, "missing MakeTool registration"


def test_control_fids_is_not_dev_only():
    """FID ops are documented Openplanet API; they must ship in release builds."""
    text = _mcp_tools()
    idx = text.index('name == "ControlFids"')
    dev_block = text.find("#if DEV")
    while dev_block >= 0:
        dev_end = text.find("#endif", dev_block)
        assert not (dev_block < idx < dev_end), \
            "ControlFids must not be registered only under #if DEV"
        dev_block = text.find("#if DEV", dev_end if dev_end >= 0 else dev_block + 1)


def test_schema_requires_action_only():
    text = _mcp_tools()
    line = next(l for l in text.splitlines() if 'MakeTool("ControlFids"' in l)
    assert '"required":["action"]' in line
    for key in ("drive", "path", "kind", "query", "limit", "from_ptr", "dest",
                "force", "hookMethod", "withFiles", "includeNod"):
        assert f'"{key}"' in line, key
    assert '"from":' not in line


def test_description_names_the_official_ops_and_drives():
    text = _mcp_tools()
    line = next(l for l in text.splitlines() if 'MakeTool("ControlFids"' in l)
    lower = line.lower()
    for word in ("preload", "updatetree", "extract", "getfullpath", "fromnod",
                 "drives", "list", "game", "user", "fake", "resource"):
        assert word in lower, word
    assert "fids" in lower
    assert "from_ptr" in lower


def test_impl_calls_documented_openplanet_api():
    text = _impl()
    for fn in (
        "Fids::GetGame",
        "Fids::GetUser",
        "Fids::GetFake",
        "Fids::GetResource",
        "Fids::GetProgramData",
        "Fids::GetGameFolder",
        "Fids::GetUserFolder",
        "Fids::GetFakeFolder",
        "Fids::GetResourceFolder",
        "Fids::GetProgramDataFolder",
        "Fids::Preload",
        "Fids::Extract",
        "Fids::GetFullPath",
        "Fids::UpdateTree",
        "GetFidFromNod",
    ):
        assert fn in text, fn
    # Nested lookup helpers exist in the official API; v1 resolves via Get{Drive}.
    assert "CopyToFileRelative" in text


def test_impl_actions_and_error_on_unknown():
    text = _impl()
    for action in ("drives", "get", "list", "preload", "updateTree",
                   "extract", "getFullPath", "fromNod"):
        assert f'action == "{action}"' in text, action
    assert "BAD_ACTION" in text
    assert "NOT_FOUND" in text
    assert "TREE_TOO_BROAD" in text
    assert "PRELOAD_FAILED" in text
    assert "EXTRACT_FAILED" in text
    assert "NO_FID" in text


def test_update_tree_refuses_empty_game_root_without_force():
    text = _impl()
    assert 'drive == "game" && path.Length == 0 && !force' in text
    assert "TREE_TOO_BROAD" in text


def test_extract_rejects_parent_and_absolute_dest():
    text = _impl()
    assert 'dest.Contains("..")' in text
    assert "BAD_DEST" in text
    assert "hookMethod" in text
    # hookMethod must not be forced on.
    assert "hookMethod = input.HasKey(\"hookMethod\") && bool(input[\"hookMethod\"])" in text


def test_list_is_capped():
    text = _impl()
    assert "FIDS_LIST_MAX = 400" in text
    assert "FIDS_LIST_DEFAULT = 80" in text
    assert "limit > FIDS_LIST_MAX" in text


def test_list_treats_auto_as_both_and_rejects_unknown_kind():
    text = _impl()
    assert 'kind == "all" || kind == "auto"' in text
    assert "BAD_KIND" in text


def test_fid_json_stamps_reusable_drive_relative_path():
    text = _impl()
    assert "FidsStampLocation" in text
    assert 'o["path"] = path' in text
    assert "GetFidsFile" in text


def test_guide_is_registered():
    text = _guides()
    assert '_RegisterGuide("fids"' in text
    assert "ControlFids" in text
    assert "UpdateTree" in text or "updateTree" in text
    assert "existsOnDisk" in text
    assert "from_ptr" in text
    assert "from=app|editor|challenge" in text or "from=app" in text


def test_from_nod_uses_from_ptr_not_named_live_nobs():
    text = _impl()
    assert "from_ptr" in text
    assert "FidsNodFromPtr" in text
    assert "TypeInfoResolveFrom" not in text
    assert "BAD_PTR" in text
    assert "FidsPointerOfNod" in text


def test_from_nod_refuses_readable_non_vtable_words():
    """0x3F800000 is 8-aligned and can be mapped (IEEE 1.0). Must not wrap."""
    text = _impl()
    assert "Dev::BaseAddress()" in text
    assert "0x3000000" in text
    assert "LogCrash_EA180000000CBBE0" in text or "3F800000" in text
