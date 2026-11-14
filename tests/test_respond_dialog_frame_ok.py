"""RespondDialog frame-ok never guesses between several cards.

Live case (2026-11-15): on the server join card (FrameDialogJoin: ButtonJoin,
ButtonSpectator, ButtonCancel, plus a ButtonSelection per map row) frame-ok
fired the first ButtonSelection, a map row, and reported success while the card
stayed up. These pins hold the order; the game types keep it out of stock
AngelScript, so the click itself is checked live.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def _body(signature):
    start = MCP_TOOLS.index(signature)
    brace = MCP_TOOLS.index("{", start)
    depth = 0
    for i in range(brace, len(MCP_TOOLS)):
        depth += {"{": 1, "}": -1}.get(MCP_TOOLS[i], 0)
        if depth == 0:
            return MCP_TOOLS[start : i + 1]
    raise AssertionError(f"unterminated: {signature}")


def test_several_cards_without_ok_refuse_before_any_click():
    body = _body("Json::Value@ RespondDialog(")
    frame_ok = body[body.index('// One card: its ButtonSelection is the OK.'):]
    collect = frame_ok.index("_DlgCollectNamed(menu.CurrentFrame, selectionId.Value, 0, cards);")
    single = frame_ok.index("if (cards.Length == 1) @btn = cards[0];")
    ok = frame_ok.index('_DlgFindChildRecursive(menu.CurrentFrame, "ButtonOk", 0)')
    refuse = frame_ok.index("if (btn is null && cards.Length > 1) return _FrameOkAmbiguousError(")
    click = frame_ok.index("btn.OnAction();")
    assert collect < single < ok < refuse < click


def test_refusal_names_the_cards_and_the_next_call():
    body = _body("Json::Value@ _FrameOkAmbiguousError(")
    assert '"AMBIGUOUS_FRAME"' in body
    assert "_DlgCardId(cards[i])" in body and 'output["cards"] = list;' in body
    assert "MenuDialogFrameHint(frame)" in body and "ClickClassicMenuControl {id}" in body


def test_frame_ok_reports_whether_the_frame_went_away():
    body = _body("Json::Value@ RespondDialog(")
    after = body[body.index("output[\"after\"] = BasicDialogSummary();"):]
    assert 'output["frameClosed"] = !stillUp;' in after
    assert "_MenuFrameIsUp(menuFrameActed)" in after
