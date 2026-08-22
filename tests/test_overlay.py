"""Source contract for ControlOverlay (no live game required).

These are text assertions, which is what the rest of this suite does and all it
can do without the game. They are worth having anyway: the failure this file
guards against is a tool that is written but not *reachable*, because
registration in this repo is three separate edits in McpTools.as (the
sync-dispatch allowlist, the dispatch branch, and the MakeTool entry) and
omitting any one of them leaves a tool that compiles and cannot be called.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


def test_overlay_uses_the_documented_openplanet_api():
    text = (SRC / "Overlay.as").read_text()
    # The whole point of this tool over a memory-offset approach: these four
    # are documented Openplanet API and cannot break on a game update.
    for fn in ("UI::ShowOverlay()", "UI::HideOverlay()",
               "UI::IsOverlayShown()", "UI::IsRendering()"):
        assert fn in text, fn


def test_overlay_reports_shown_and_rendering_separately():
    text = (SRC / "Overlay.as").read_text()
    # Collapsing these two would be wrong: the global option "Hide overlay on
    # hidden game UI" makes IsRendering() false while IsOverlayShown() stays
    # true, so one cannot substitute for the other.
    assert '"shown"' in text
    assert '"rendering"' in text
    assert "OverlayStateJson" in text


def test_overlay_actions_and_error_on_unknown():
    text = (SRC / "Overlay.as").read_text()
    for action in ("get", "show", "hide", "toggle"):
        assert f'action == "{action}"' in text, action
    # An unrecognised action must be an error, not a silent no-op that reports
    # the unchanged state as success.
    assert "BAD_ACTION" in text


def test_overlay_get_neither_settles_nor_writes():
    """`get` must be cheap enough to poll and must not change the overlay."""
    text = (SRC / "Overlay.as").read_text()
    get_branch = text.split('if (action == "get")', 1)[1].split("} else", 1)[0]
    assert "OverlaySettle" not in get_branch
    assert "ShowOverlay" not in get_branch
    assert "HideOverlay" not in get_branch


def test_overlay_settle_is_bounded():
    text = (SRC / "Overlay.as").read_text()
    assert "settleFrames" in text
    assert "frames > 30" in text, "settle must be capped, an unbounded yield loop hangs the tool"
    assert "yield()" in text


def test_overlay_reports_as_requested_distinctly_from_changed():
    """A caller retrying a dropped write must not loop on 'already correct'."""
    text = (SRC / "Overlay.as").read_text()
    assert '"asRequested"' in text
    assert '"changed"' in text


def test_control_overlay_is_registered_at_all_three_points():
    text = (SRC / "McpTools.as").read_text()
    assert 'name == "ControlOverlay"' in text, "missing from the sync-dispatch allowlist"
    assert 'if (name == "ControlOverlay") return ControlOverlay(input);' in text, \
        "missing dispatch branch"
    assert 'MakeTool("ControlOverlay"' in text, "missing MakeTool registration"


def test_control_overlay_description_points_at_the_camera_interaction():
    """The reason this tool exists should be discoverable from the tool list."""
    text = (SRC / "McpTools.as").read_text()
    line = next(l for l in text.splitlines() if 'MakeTool("ControlOverlay"' in l)
    assert "ControlPlayCamera" in line
    # And must not be confused with the game HUD, which is a different API.
    assert "OverlayHide" in line
