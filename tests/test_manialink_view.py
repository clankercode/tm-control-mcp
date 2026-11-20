"""ListManialinkPages / ViewManialinkPage: pure formatting helpers in stock
AngelScript, plus source contracts for the game side (registration, schema,
read-only status, password redaction, every layer source covered).

The live tree walk needs the game.
"""
import json
import re
import subprocess
from pathlib import Path

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "ManialinkViewPolicy.as"
VIEW = (ROOT / "src" / "ManialinkView.as").read_text()
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()
TOOLS = ("ListManialinkPages", "ViewManialinkPage")


def run_policy(runner, tmp_path, body):
    case = tmp_path / "manialink_view_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_short_type_drops_the_manialink_prefix(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MlShortType("CGameManialinkLabel") == "label", "label");
    Check(MlShortType("CGameManialinkTextEdit") == "textedit", "textedit");
    Check(MlShortType("CGameManialinkFrame") == "frame", "frame");
    Check(MlShortType("CControlFoo") == "ccontrolfoo", "unknown kept, lower-cased");
    Check(MlShortType("CGameManialink") == "?", "bare prefix");
    Check(MlShortType("") == "?", "empty");
    ''')


def test_text_is_one_line_quoted_and_capped(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MlQuoteText("Play") == "\"Play\"", "plain");
    Check(MlQuoteText("a\nb") == "\"a\\nb\"", "newline escaped");
    Check(MlQuoteText("a\r\nb") == "\"a\\nb\"", "CRLF one escape");
    Check(MlQuoteText("say \"hi\"") == "\"say \\\"hi\\\"\"", "quotes escaped");
    Check(MlQuoteText("a\\b") == "\"a\\\\b\"", "backslash escaped");
    string longText = "";
    for (uint i = 0; i < 70; i++) longText += "x";
    string q = MlQuoteText(longText);
    Check(q.Length == 1 + 60 + 3 + 1, "capped at 60 + ellipsis");
    Check(q.SubStr(q.Length - 4) == "...\"", "ellipsis inside the quotes");
    string tail = MlQuoteText(longText + "/icon.dds", true);
    Check(tail.SubStr(tail.Length - 10) == "/icon.dds\"", "keepTail keeps the filename");
    Check(tail.SubStr(0, 4) == "\"...", "keepTail ellipsis at the front");
    string slashes = "";
    for (uint i = 0; i < 70; i++) slashes += "\\";
    string qs = MlQuoteText(slashes);
    Check(qs.SubStr(qs.Length - 4) == "...\"", "cut before escaping: no dangling backslash before the closing quote");
    ''')


def test_utf8_cuts_never_split_a_sequence(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    string e = "\xC3\xA9";                      // é, 2 bytes
    Check(MlUtf8Prefix("ab" + e, 3) == "ab", "prefix backs off a split 2-byte char");
    Check(MlUtf8Prefix("ab" + e, 4) == "ab" + e, "prefix fits");
    Check(MlUtf8Prefix("abc", 2) == "ab", "ascii prefix");
    string g = "\xEE\x80\x80";                 // private-use glyph, 3 bytes
    Check(MlUtf8Prefix("a" + g, 2) == "a", "3-byte char backed off at byte 1");
    Check(MlUtf8Prefix("a" + g, 3) == "a", "3-byte char backed off at byte 2");
    Check(MlUtf8Suffix(e + "ab", 3) == "ab", "suffix skips a split char");
    Check(MlUtf8Suffix(g + "a", 3) == "a", "suffix skips 3-byte char");
    Check(MlUtf8Suffix("abc", 2) == "bc", "ascii suffix");
    string longE = "";
    for (uint i = 0; i < 40; i++) longE += e;   // 80 bytes
    string q = MlQuoteText(longE);
    Check(q == "\"" + MlUtf8Prefix(longE, 60) + "...\"", "quote uses the boundary-safe cut");
    ''')


def test_node_line_layout(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<string> none;
    array<string> cls = {"zone", "nav"};
    array<string> extras = {"\"Play\"", "", "[focused]"};
    Check(MlNodeLine(0, "frame", "", none, none) == "frame", "anonymous root");
    Check(MlNodeLine(2, "label", "title", none, none) == "    label#title", "indent two per level");
    Check(MlNodeLine(1, "quad", "bg", cls, extras) == "  quad#bg .zone.nav \"Play\" [focused]", "classes and extras, empty extra skipped");
    Check(MlNodeLine(0, "label", "", cls, none) == "label .zone.nav", "classes without id");
    ''')


def test_only_bare_single_child_frames_collapse(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MlCollapseFrame(true, "", 0, 1, false, false), "anonymous wrapper");
    Check(!MlCollapseFrame(true, "frame-main", 0, 1, false, false), "id is information");
    Check(!MlCollapseFrame(true, "", 1, 1, false, false), "class is information");
    Check(!MlCollapseFrame(true, "", 0, 2, false, false), "several children");
    Check(!MlCollapseFrame(true, "", 0, 0, false, false), "empty frame still printed");
    Check(!MlCollapseFrame(false, "", 0, 1, false, false), "not a frame");
    Check(!MlCollapseFrame(true, "", 0, 1, true, false), "hidden frame keeps its [hidden] line");
    Check(!MlCollapseFrame(true, "", 0, 1, false, true), "focused frame keeps its [focused] line");
    ''')


def test_brief_view_rules(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<string> nav = {"component-navigation-item"};
    array<string> zone = {"component-navigation-item-zone"};
    array<string> pager = {"quad-base", "news-pager", "component-navigation-item"};
    array<string> none;
    Check(MlIsClickable(nav), "nav item");
    Check(MlIsClickable(pager), "nav class among others");
    Check(!MlIsClickable(zone), "hitbox zone is not a separate target");
    Check(!MlIsClickable(none), "no classes");

    Check(MlBriefKeep(false, true, 0, false, false), "label with text kept");
    Check(!MlBriefKeep(false, false, 0, false, false), "empty label / quad dropped");
    Check(!MlBriefKeep(true, false, 0, false, false), "empty frame dropped");
    Check(MlBriefKeep(true, false, 1, false, false), "frame holding something kept");
    Check(MlBriefKeep(false, false, 0, false, true), "clickable kept without text");
    Check(MlBriefKeep(false, false, 0, true, false), "focus kept");

    Check(MlBriefCollapse(true, false, 1, 0, false, false), "layout wrapper collapses");
    Check(!MlBriefCollapse(true, true, 1, 0, false, false), "clickable never collapses");
    Check(!MlBriefCollapse(true, false, 1, 3, false, false), "depth-cut frame keeps its (+N children)");
    Check(!MlBriefCollapse(true, false, 2, 0, false, false), "several children");
    Check(!MlBriefCollapse(true, false, 1, 0, true, false), "hidden frame keeps [hidden]");

    Check(MlBriefAbsorb("label", 0, false, false), "button takes its label text");
    Check(!MlBriefAbsorb("quad", 0, false, false), "not a label");
    Check(!MlBriefAbsorb("label", 0, true, false), "hidden label stays visible as such");
    Check(!MlBriefAbsorb("label", 0, false, true), "focused label keeps its line");
    ''')


def test_page_selector(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MlPageMatches("menu:12", "menu:12", "page_homepage"), "ref exact");
    Check(!MlPageMatches("menu:1", "menu:12", "page_homepage"), "ref is not a prefix");
    Check(MlPageMatches("Page_HomePage", "menu:12", "page_homepage"), "name case-insensitive");
    Check(!MlPageMatches("Page_Home", "menu:12", "page_homepage"), "name is exact");
    Check(!MlPageMatches("", "menu:12", ""), "empty selector matches nothing");
    Check(MlLower("AbC-Z_9") == "abc-z_9", "ascii lower");
    Check(MlSelectorIsRef("uiConfig0:3") && !MlSelectorIsRef("Page_Home"), "ref vs name");
    ''')


def test_registered_at_all_three_points():
    for name in TOOLS:
        assert f'name == "{name}"' in MCP_TOOLS, f"{name} missing from IsToolName"
        assert f'if (name == "{name}") return {name}(input);' in MCP_TOOLS, f"{name} missing dispatch"
        assert f'MakeTool("{name}"' in MCP_TOOLS, f"{name} missing MakeTool registration"


def schema(name):
    line = next(l for l in MCP_TOOLS.splitlines() if f'MakeTool("{name}"' in l)
    match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
    assert match, "could not extract schema"
    return json.loads(match.group(1))


def test_schemas():
    assert schema("ListManialinkPages")["properties"] == {"includeHidden": {"type": "boolean"}}
    view = schema("ViewManialinkPage")
    assert set(view["properties"]) == {"page", "full", "find", "maxLines", "maxDepth", "includeHidden", "rawText"}
    assert view.get("required") is None, "page is optional: no page views every visible page"
    for name in TOOLS:
        assert schema(name)["additionalProperties"] is False


def test_not_an_editor_mutation():
    policy = (ROOT / "src" / "DialogPolicy.as").read_text()
    for name in TOOLS:
        assert f'"{name}"' not in policy, f"{name} is read-only and must not be refused behind a dialog"


def test_view_is_read_only():
    for call in ("Show()", "Hide()", "Focus()", "OnAction", ".Value =", "ManialinkPage =", "ManialinkPageUtf8 ="):
        assert call not in VIEW, f"ManialinkView.as must not mutate the UI ({call})"


def test_password_entries_are_redacted():
    assert "ETextFormat::Password" in VIEW and "ETextFormat::Newpassword" in VIEW
    assert VIEW.count('"value=<password>"') == 2, "entry and textedit both redact"
    assert "_MlIsPasswordFormat(int(edit.TextFormat))" in VIEW


def test_value_type_buffers_are_never_handled():
    assert "MwFastBuffer" not in VIEW.replace("MwFastBuffer is a value type", ""), "index UILayers through the owner"


def test_game_side_matches_through_the_tested_helper():
    assert "MlPageMatches(selector, r.ref" in VIEW, "selector matching must use the tested policy helper"
    assert "omitted.Add(r.ref);" in VIEW, "omitted pages must not read names (page-XML copy each)"


def test_drawn_means_root_frame_shown_and_loading_screens_skipped():
    # Live 2026-11-20: menu layers keep IsVisible under a map; only their
    # MainFrame is hidden. Page_LoadingScreen reports visible everywhere.
    body = VIEW[VIEW.index("bool _MlLayerVisible"):VIEW.index("string _MlLayerType")]
    assert "page.MainFrame.Visible" in body
    assert '== "LoadingScreen"' in VIEW and 'output["loadingScreenPages"]' in VIEW
    assert 'output["emptyPages"]' in VIEW


def test_truncation_is_reported():
    for token in ('output["truncated"]', 'output["depthLimited"]', 'output["omittedPages"]', '"... truncated at maxLines="'):
        assert token in VIEW, token


def test_every_layer_source_is_collected():
    for source in ('"menu"', '"playground"', '"ui"', '"clientUi"', '"uiConfig"', '"editor"'):
        assert source in VIEW, f"layer source {source} not collected"


ACTIONS = (ROOT / "src" / "ManialinkActions.as").read_text()
READINESS = (ROOT / "src" / "Readiness.as").read_text()


def test_text_filter_and_wait_cap(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MlIdLooksClickable("button-toggle-ghost"), "quad icon button by id");
    Check(MlIdLooksClickable("button_ok"), "underscore form");
    Check(!MlIdLooksClickable("label-button-text"), "button later in the id");
    Check(!MlIdLooksClickable(""), "anonymous");
    Check(MlTextContains("frame#button-play \"Play\"", "PLAY"), "case-insensitive");
    Check(MlTextContains("anything", ""), "empty needle matches");
    Check(!MlTextContains("Records", "rank"), "no match");
    Check(MlClampWaitMs(-5) == 0, "negative to zero");
    Check(MlClampWaitMs(20000) == 20000, "kept");
    Check(MlClampWaitMs(300000) == 300000, "cap is allowed");
    Check(MlClampWaitMs(1800000) == 300000, "capped at 5 minutes");
    ''')


def test_click_tool_registered():
    assert 'name == "ClickManialinkControl"' in MCP_TOOLS
    assert 'if (name == "ClickManialinkControl") return ClickManialinkControl(input);' in MCP_TOOLS
    s = schema("ClickManialinkControl")
    assert s["required"] == ["page", "id"]
    assert set(s["properties"]) == {"page", "id", "index", "full", "allowHidden"}


def test_click_refuses_what_a_player_cannot_click():
    body = ACTIONS[ACTIONS.index("Json::Value@ ClickManialinkControl"):ACTIONS.index("bool ManialinkConditionMet")]
    assert '"NOT_DRAWN"' in body and "allowHidden" in body
    assert body.index("ManialinkControlDrawn") < body.index("OnAction()"), "drawn check before the click"
    # Live 2026-11-20: ids repeat per list row (18 button-toggle-ghost on the
    # records list). index counts the lines the view prints with that id, so
    # the click lands on the line the agent read (review 2026-11-20).
    assert "ManialinkPrintedControls(page, controlId, full, allowHidden)" in body
    assert 'output["matches"]' in body
    assert "_FindNavZoneInSubtree" in body, "clicks the Nadeo hitbox like ClickMenuButton"


def test_printed_controls_mirror_the_view():
    body = VIEW[VIEW.index("void _MlPrintedById"):VIEW.index("void _MlEmit")]
    # same build as the view, same collapse rule as _MlEmit, no cuts
    assert "_MlBuild(w, mainFrame, 0)" in body
    assert "MlCollapseFrame(n.isFrame, n.id, n.classes.Length, n.kids.Length, n.hidden, n.focused)" in body
    assert "w.maxDepth = 64" in body and "ML_VIEW_MAX_LINES_CAP" in body
    assert "@n.ctrl = ctrl;" in VIEW


def test_find_matches_only_printed_text_and_keeps_depth_markers():
    filt = VIEW[VIEW.index("_MlNode@ _MlFilter"):VIEW.index("void _MlPrintedById")]
    assert "_MlShownValue(n, full)" in filt
    assert "n.cutChildren = 0" not in filt


def test_gone_flags_a_page_that_never_matched():
    assert 'last["pageFound"]' in ACTIONS
    wait = READINESS[READINESS.index("Json::Value@ WaitUntil"):]
    assert 'output["pageEverFound"]' in wait and "trivially true" in wait


def test_ui_wait_never_sleeps_past_its_budget():
    wait = READINESS[READINESS.index("Json::Value@ WaitUntil"):]
    assert "used >= uint64(timeoutMs) ? 0 : Math::Min(slice, uint(uint64(timeoutMs) - used))" in wait


def test_name_lookups_are_cached_across_polls():
    assert "_MlCachedName(pages[i])" in ACTIONS
    assert "e.xmlLength != len" in ACTIONS, "refresh when a layer's page is replaced"


def test_drawn_walks_every_ancestor():
    body = ACTIONS[ACTIONS.index("bool ManialinkControlDrawn"):ACTIONS.index("string ManialinkControlText")]
    assert "_MlLayerVisible(page.layer)" in body and "cur.Parent" in body and "cur.Visible" in body


def test_manialink_wait_is_capped_at_five_minutes():
    assert 'condLower == "manialink"' in READINESS
    assert 'cond == "manialink"' in READINESS
    wait = READINESS[READINESS.index("Json::Value@ WaitUntil"):]
    assert "MlClampWaitMs(" in wait
    # The cap covers loading too: checked before the loading branch.
    assert wait.index("if (uiWait && now - t0 >= uint64(timeoutMs)) break;") < wait.index("if (loading) {")
    assert 'string(input["page"]).Length == 0' in wait, "page is required"
    wait_schema = schema("WaitUntil")
    assert {"id", "index", "full", "text", "state"} <= set(wait_schema["properties"])
    line = next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("WaitUntil"' in l)
    assert "300000 (5 min)" in line


def test_entry_values_strip_format_codes():
    # Live 2026-11-20: Page_LocalServer entries read "$t$iServer name".
    assert VIEW.count("rawText ? v : Text::StripFormatCodes(v)") == 2, "entry and textedit"


def test_find_filters_after_brief_build():
    assert "_MlFilter(root, w.find, w.full)" in VIEW
    assert 'output["noMatchPages"]' in VIEW
    assert '"find":{"type":"string"}' in next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("ViewManialinkPage"' in l)


def test_menu_only_tools_point_at_context_wide_ones():
    for name in ("GetUILayers", "GetLayerTree", "ListMenuManialinkControls", "FindControlsByLabel",
                 "FindMenuButtons", "ClickMenuButton", "GetActiveMenuPages"):
        line = next(l for l in MCP_TOOLS.splitlines() if f'MakeTool("{name}", "' in l)
        assert "Menu only" in line, name
