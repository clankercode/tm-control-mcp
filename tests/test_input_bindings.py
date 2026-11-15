"""GetInputBindings: pure helpers in stock AngelScript, plus source contracts.

The live part (devices, pads, InputBindings_UpdateList, GetActionBinding) needs the
game; these checks pin what can be checked without it, including that the tool
stays read-only and puts the shared binding list back.
"""
import json
import re
from pathlib import Path
import subprocess

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "InputBindingsPolicy.as"
TOOL = (ROOT / "src" / "InputBindings.as").read_text()
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()


def run_policy(runner, tmp_path, body):
    case = tmp_path / "input_bindings_case.as"
    case.write_text("void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_action_names_lose_their_translation_context(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(BindingActionName("|Input|Give up") == "Give up", "context prefix");
    Check(BindingActionName("|A||B|Respawn") == "Respawn", "several groups");
    Check(BindingActionName("Accelerate") == "Accelerate", "no prefix");
    Check(BindingActionName("|Unterminated") == "|Unterminated", "unterminated prefix kept");
    Check(BindingActionName("|") == "|", "lone bar kept");
    Check(BindingActionName("") == "", "empty");
    Check(BindingActionName("Steer | left") == "Steer | left", "bar inside the name");
    ''')


def test_filter_matches_action_or_binding_and_bound_only_drops_empty_rows(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(BindingRowKept("give up", "delete", "delete", "", false), "no filter keeps");
    Check(BindingRowKept("give up", "", "", "", false), "unbound kept by default");
    Check(!BindingRowKept("give up", "", "", "", true), "boundOnly drops unbound");
    Check(BindingRowKept("give up", "delete", "delete", "", true), "boundOnly keeps bound");
    Check(BindingRowKept("give up", "delete", "delete", "give", false), "matches action");
    Check(BindingRowKept("respawn", "enter, a", "return,a", "enter", false), "matches display");
    Check(BindingRowKept("respawn", "enter", "return", "return", false), "matches raw");
    Check(!BindingRowKept("horn", "z", "z", "delete", false), "no match");
    Check(!BindingRowKept("give up", "", "", "give", true), "boundOnly applies before filter");
    ''')


def test_list_signature_is_content_identity(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    array<string> none;
    array<string> oneEmpty = {""};
    array<string> joined = {"a\nb"};
    array<string> split = {"a", "b"};
    array<string> a = {"Up", "Delete"};
    array<string> b = {"Up", "Delete"};
    array<string> c = {"Up", "Return"};
    Check(BindingListSignature(none) != BindingListSignature(oneEmpty), "empty vs one unbound row");
    Check(BindingListSignature(joined) != BindingListSignature(split), "one row with a newline vs two rows");
    Check(BindingListSignature(a) == BindingListSignature(b), "same content");
    Check(BindingListSignature(a) != BindingListSignature(c), "different content");
    ''')


def test_registered_at_all_three_points():
    assert 'name == "GetInputBindings"' in MCP_TOOLS, "missing from IsToolName"
    assert 'if (name == "GetInputBindings") return GetInputBindings(input);' in MCP_TOOLS, "missing dispatch"
    assert 'MakeTool("GetInputBindings"' in MCP_TOOLS, "missing MakeTool registration"


def test_schema():
    line = next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("GetInputBindings"' in l)
    match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
    assert match, "could not extract schema"
    schema = json.loads(match.group(1))
    props = schema["properties"]
    assert props["filter"]["type"] == "string"
    assert props["boundOnly"]["type"] == "boolean"
    assert props["actionMap"]["type"] == "string"
    assert props["actionIds"]["type"] == "array"
    assert schema.get("additionalProperties") is False
    assert "required" not in schema


def test_tool_is_read_only():
    # The binding write paths (Dialog_BindInput & co) and raw memory writes stay out.
    assert "Dialog_" not in TOOL
    assert "Dev::Set" not in TOOL and "Dev::Write" not in TOOL
    assert "InputBindings_UpdateList(CGameManiaPlanetScriptAPI::EInputsListFilter::All, pad)" in TOOL


def test_shared_list_is_read_before_any_refill_and_put_back():
    body = TOOL[TOOL.index("Json::Value@ GetInputBindings("):]
    before = body.index("string before = ")
    first_refill = body.index("_BindingsUpdateList(")
    assert before < first_refill, "snapshot must precede the first InputBindings_UpdateList"
    assert "padSigs.Find(before)" in body
    assert 'output["sharedList"]' in body
