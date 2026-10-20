"""Run the production replacement planner in AngelScript, including deletion bounds."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_text_patch_behaviour(as_runner, tmp_path):
    case = tmp_path / "case.as"
    case.write_text(r'''
void RunTests() {
    auto p = TmMcp::PlanTextPatch("abc abc", "abc", "x", false);
    Check(p.error == "" && p.matched == 1 && p.changed && p.text == "x abc", "first only");
    @p = TmMcp::PlanTextPatch("aaa", "aa", "b", true);
    Check(p.matched == 1 && p.text == "ba", "non-overlapping matches");
    @p = TmMcp::PlanTextPatch("abc abc", "abc", "", true);
    Check(p.text == " " && p.matched == 2, "all deletion");
    @p = TmMcp::PlanTextPatch("abc", "abc", "", false);
    Check(p.text == "" && p.changed, "delete full string, no invalid snippet range");
    @p = TmMcp::PlanTextPatch("abc", "absent", "x", true);
    Check(p.text == "abc" && !p.changed && p.matched == 0, "no match");
    @p = TmMcp::PlanTextPatch("abc", "b", "b", true);
    Check(!p.changed && p.matched == 1, "identity avoids write/recompile");
    @p = TmMcp::PlanTextPatch("", "x", "y", false);
    Check(p.text == "" && !p.changed, "empty source");
    @p = TmMcp::PlanTextPatch("abc", "", "y", true);
    Check(p.error == "EMPTY_FIND", "empty needle cannot loop");
    string repeats = "a";
    for (uint i=0; i<13; i++) repeats += repeats;
    @p = TmMcp::PlanTextPatch(repeats, "a", "", true);
    Check(p.error == "TOO_MANY_MATCHES", "replacement work capped");
    string limit = "a";
    for (uint i=0; i<18; i++) limit += limit;
    @p = TmMcp::PlanTextPatch(limit, "a", "b", false);
    Check(p.error == "" && p.text.Length == TmMcp::TEXT_PATCH_MAX, "exact limit");
    @p = TmMcp::PlanTextPatch(limit, "a", "bb", false);
    Check(p.error == "TEXT_TOO_LARGE", "growth rejected before assignment");
    @p = TmMcp::PlanTextPatch(limit + "a", "a", "", true);
    Check(p.error == "TEXT_TOO_LARGE", "oversize source rejected");
    Check(TmMcp::IsUserEditorScriptPath("Scripts/EditorPlugins/Example.Script.txt"), "editor script");
    string[] bad = {"Scripts/Modes/Race.Script.txt", "Scripts/EditorPlugins/../Race.Script.txt", "Scripts/EditorPlugins//A.Script.txt", "/Scripts/EditorPlugins/A.Script.txt", "Scripts/EditorPlugins/A.Script.txt\n", "Scripts/EditorPlugins/A.txt", "C:/Scripts/EditorPlugins/A.Script.txt", "Scripts\\EditorPlugins\\A.Script.txt"};
    for (uint i=0; i<bad.Length; i++) Check(!TmMcp::IsUserEditorScriptPath(bad[i]), "bad path");
}
''')
    result = subprocess.run([str(as_runner), str(ROOT / "src/TextMutationPolicy.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
