"""EditNewMap must never leave the shared Stadium decoration fid swapped.

Live case (2026-11-15, Openplanet-Old.log #70..#109): EditNewMap from a dirty
editor swapped the standard fid while the old editor sat behind its save
prompt. After "no", the fid's nod had an empty IdName; the next call swapped
it anyway and returned early without restoring, and every later call ran
EditNewMap2('Stadium', 'NoStadium48x48Day'), which does nothing.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def _body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


CO = _body(MCP_TOOLS, "void _EditNewMapCoroutine(")
TOOL = _body(MCP_TOOLS, "Json::Value@ EditNewMapTool(")


def test_leaves_the_map_before_touching_decorations():
    leave = CO.index("app.BackToMainMenu();")
    assert leave < CO.index("Fids::Preload(")
    assert leave < CO.index("Dev::SetOffset(")
    dialog_stop = CO.index("blocked by dialog after BackToMainMenu")
    assert dialog_stop < CO.index("Fids::Preload(")
    assert CO.index("if (g_EditNewMapDecoSwapped)") < CO.index("Fids::Preload(")


def test_standard_fid_is_verified_and_swap_is_exclusive_with_failure():
    check = CO.index("if (stdId != STD_DECO_NOD) {")
    swap = CO.index("Dev::SetOffset(stdFid")
    assert check < swap
    # The swap sits in the else arm of the verification, so the failure
    # return below never runs with a swap in place.
    assert "} else if (stdNod.IdName != chosenDeco.IdName) {" in CO[check:swap]
    after_swap = CO[swap:]
    failure = after_swap[after_swap.index("if (fail.Length > 0) {"):]
    failure = failure[: failure.index("return;")]
    assert "chosenDeco.MwRelease();" in failure
    assert "chosenDeco.DecoSize.SizeX = origSize.x;" in failure
    # Every path that reaches EditNewMap2 restores through one helper.
    assert CO.count("if (swapped) RestoreEditNewMapDecoSwap();") == 1
    assert CO.index("EditNewMap2(") < CO.index("if (swapped) RestoreEditNewMapDecoSwap();")


def test_restore_is_shared_with_shutdown():
    restore = _body(MCP_TOOLS, "void RestoreEditNewMapDecoSwap(")
    assert "if (!g_EditNewMapDecoSwapped) return;" in restore
    assert "Dev::SetOffset(g_DecoSwapFid" in restore
    assert "g_EditNewMapDecoSwapped = false;" in restore
    server = (ROOT / "src" / "Server.as").read_text()
    shutdown = _body(server, "void Shutdown(")
    assert shutdown.index("RestoreEditNewMapDecoSwap()") < shutdown.index("StopToolCalls();")


def test_decoration_size_is_restored_even_when_the_editor_never_opened():
    tail = CO[CO.index("if (swapped) RestoreEditNewMapDecoSwap();"):]
    assert "if (mapSize.x > 0) {" in tail
    assert "while (opened) {" in tail


def test_tool_refuses_overlap_and_reports_coroutine_failure():
    busy = TOOL.index("if (g_EditNewMapDecoSwapped) {")
    assert busy < TOOL.index('_PrepareModuleChange("EditNewMap")') < TOOL.index("startnew(")
    assert '"EDITNEWMAP_BUSY"' in TOOL
    assert 'output["status"] = g_EditNewMapStatus;' in TOOL
    assert 'g_EditNewMapStatus.StartsWith("error: ")' in TOOL
    assert '"EDITNEWMAP_FAILED"' in TOOL
    # Coroutine early exits record why (they used to only warn).
    assert "warn(\"TM Control MCP EditNewMap:" not in CO
    assert CO.count("_EditNewMapFail(seq,") >= 6
