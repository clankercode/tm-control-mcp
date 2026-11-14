"""Unknown-tool suggestions: run the in-game [Test] bodies in stock AngelScript.

src/ToolNameSuggest_Test.as is the single source of the cases. Stock AngelScript
has no [Test] attribute or Tests::Context, so the attribute lines are dropped and
a Context adapter maps its asserts onto the runner's Check.
"""
from pathlib import Path
import re
import subprocess

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "ToolNameSuggest.as"
CASES = ROOT / "src" / "ToolNameSuggest_Test.as"

CONTEXT = r'''
namespace Tests {
    class Context {
        void AssertTrue(bool ok, const string &in message = "") { Check(ok, message); }
        void AssertFalse(bool ok, const string &in message = "") { Check(!ok, message); }
        void AssertSame(const string &in actual, const string &in expected, const string &in message = "") {
            Check(actual == expected, message + ": got '" + actual + "', expected '" + expected + "'");
        }
    }
}
'''


def test_in_game_cases_pass_in_stock_angelscript(as_runner, tmp_path):
    source = CASES.read_text()
    names = re.findall(r"\[Test\]\s*void (\w+)\(Tests::Context@ ctx\)", source)
    assert len(names) >= 5, names
    cases = tmp_path / "cases.as"
    cases.write_text(re.sub(r"^\s*\[Test\]\s*$", "", source, flags=re.M))
    runner = tmp_path / "run.as"
    calls = "\n".join(f"    Tests::{name}(ctx);" for name in names)
    runner.write_text(CONTEXT + "void RunTests() {\n    auto ctx = Tests::Context();\n" + calls + "\n}\n")
    result = subprocess.run([str(as_runner), str(POLICY), str(cases), str(runner)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_every_unknown_name_path_uses_the_shared_error():
    calls = (ROOT / "src" / "ToolCalls.as").read_text()
    admission = calls[calls.index("Json::Value@ ValidateToolCallName("):]
    assert "return UnknownToolError(name);" in admission[: admission.index("\n    }\n")]
    assert "UnknownToolError(toolName)" in (ROOT / "src" / "AsyncDispatchLocal.as").read_text()
    dispatch = (ROOT / "src" / "McpTools.as").read_text()
    assert 'MakeError("unknown tool: "' not in dispatch
    assert "return UnknownToolError(name);" in dispatch
