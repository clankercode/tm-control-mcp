"""Execute the entire production tool in stock AngelScript with API mocks.

The mocks model native map reference ownership, editor replacement at a yield,
and reload faults. They do not prove the live game's ABI or script readiness.
"""
from pathlib import Path
import subprocess

import pytest

from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/EditorScriptPlugins.as"

from as_json_mocks import JSON_MOCKS

MOCKS = JSON_MOCKS + r'''
string mode = "MapEditor";
uint addRefs = 0, releases = 0, yields = 0, transitions = 0;
bool loading = false, shadows = false, crash = false, throwReload = false, throwObservation = false;
class CGameCtnChallenge {
    uint refs = 0;
    string uid = "identical-metadata";
    void MwAddRef() { refs++; addRefs++; }
    void MwRelease() { Check(refs > 0, "balanced native reference"); refs--; releases++; }
}
CGameCtnChallenge@ currentMap = CGameCtnChallenge();
class CGameCtnEditorFree {
    array<string> names = {"initial"};
    uint reloads = 0;
    bool stale = false;
    array<string>@ get_ForcedPluginsNames() property {
        Check(!stale, "stale editor buffer read after yield"); return names;
    }
    void ReloadPlugins() {
        Check(!stale, "no reload on stale editor");
        Check(!loading && !shadows && !crash, "guards must run before native reload");
        Check(currentMap !is null && currentMap.refs == 1, "map owned before native call");
        reloads++;
        if (throwReload) Check(false, "simulated native exception");
    }
}
class CTrackMania { CGameCtnEditorFree@ editor = CGameCtnEditorFree(); }
CTrackMania@ app = CTrackMania();
CTrackMania@ GetApp() { return app; }
void yield() {
    yields++;
    Check(currentMap !is null && currentMap.refs == 1, "map owned across yield");
    if (transitions == 1) {
        app.editor.stale = true;
        @app.editor = CGameCtnEditorFree();
        app.editor.names = {"fresh-editor"};
    } else if (transitions == 2) {
        @currentMap = CGameCtnChallenge();
    } else if (transitions == 3) {
        app.editor.stale = true; @app.editor = null;
    } else if (transitions == 4) {
        @currentMap = null;
    } else if (transitions == 5) loading = true;
    else if (transitions == 6) shadows = true;
    else if (transitions == 7) crash = true;
    else if (transitions == 8) @app = null;
    else if (transitions == 9) throwObservation = true;
}
namespace TmMcp {
    string DetectGameModeName() { return mode; }
    CGameCtnEditorFree@ GetEditor() { return app is null ? null : app.editor; }
    CGameCtnChallenge@ GetChallenge() { return currentMap; }
    bool IsLoadingLike(CTrackMania@ value) { return value !is null && loading; }
    bool WaitLooksLikeLightmapCompute() { return shadows; }
    Json::Value ManiaScriptDiagnostics() {
        if (throwObservation) Check(false, "simulated observation exception");
        auto output = Json::Object(); output["crashDialogDetected"] = crash; return output;
    }
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto response = Json::Object(); response["success"] = true; response["output"] = output;
        return response;
    }
    Json::Value@ MakeError(const string &in message, const string &in code) {
        auto response = Json::Object(); response["success"] = false;
        response["error"] = message; response["code"] = code; return response;
    }
}
Json::Value ReloadInput() {
    auto input = Json::Object(); input["action"] = "reload"; input["confirm"] = true; return input;
}
void CheckUnverified(Json::Value@ output) {
    Check(!bool(output["reloadVerified"]), "reload never claimed verified");
    Check(!bool(output["sourceVersionVerified"]), "source version never claimed verified");
    Check(!bool(output["readinessVerified"]), "readiness never claimed verified");
}
'''


def run_tool(as_runner, tmp_path, body):
    mocks, case = tmp_path / "mocks.as", tmp_path / "case.as"
    mocks.write_text(MOCKS)
    case.write_text("void RunTests() {\n" + body + "\n}")
    run = subprocess.run([str(as_runner), str(mocks), str(SOURCE), str(case)],
                         capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr


def test_status_is_observation_only(as_runner, tmp_path):
    run_tool(as_runner, tmp_path, r'''
        auto input = Json::Object();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(bool(response["success"]), "status success");
        auto output = response["output"];
        Check(string(output["action"]) == "status", "default action");
        Check(string(output["forcedPluginNames"][uint(0)]) == "initial", "documented names");
        Check(uint(output["forcedPluginNameCount"]) == 1, "total names");
        Check(!bool(output["forcedPluginNamesTruncated"]), "short names not truncated");
        Check(!bool(output["reloadInvoked"]) && !bool(output["reloadReturned"]), "no native call");
        CheckUnverified(output);
        Check(yields == 0 && app.editor.reloads == 0 && addRefs == 0, "read-only status");
        @app.editor = null; @currentMap = null;
        @response = TmMcp::ControlEditorScriptPlugins(input);
        Check(bool(response["success"]), "status available outside map editor");
        Check(!bool(response["output"]["editorAvailable"]), "editor absence reported");
        Check(!bool(response["output"]["mapAvailable"]), "map absence reported");
        Check(response["output"]["forcedPluginNames"].Length == 0, "no names without editor");
    ''')


def test_bounded_names_and_utf8_boundary(as_runner, tmp_path):
    run_tool(as_runner, tmp_path, r'''
        string name; for (uint i = 0; i < 255; i++) name += "x";
        name += "é";
        app.editor.names = {name};
        for (uint i = 1; i < 100; i++) app.editor.names.InsertLast("plugin");
        auto input = Json::Object();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        auto output = response["output"];
        Check(output["forcedPluginNames"].Length == 64, "names count bounded");
        Check(uint(output["forcedPluginNameCount"]) == 100, "original count reported");
        Check(bool(output["forcedPluginNamesTruncated"]), "truncation reported");
        Check(string(output["forcedPluginNames"][uint(0)]).Length == 255, "UTF-8 not split");
        string exact; for (uint i = 0; i < 128; i++) exact += "é";
        app.editor.names = {exact};
        @response = TmMcp::ControlEditorScriptPlugins(input);
        Check(string(response["output"]["forcedPluginNames"][uint(0)]) == exact, "exact boundary retained");
        Check(!bool(response["output"]["forcedPluginNamesTruncated"]), "exact byte cap not truncated");
        app.editor.names = {};
        for (uint i = 0; i < 64; i++) app.editor.names.InsertLast("plugin");
        @response = TmMcp::ControlEditorScriptPlugins(input);
        Check(response["output"]["forcedPluginNames"].Length == 64, "exact count cap retained");
        Check(!bool(response["output"]["forcedPluginNamesTruncated"]), "exact count cap not truncated");
    ''')


@pytest.mark.parametrize("setup,code", [
    ('input["confirm"] = false;', "CONFIRMATION_REQUIRED"),
    ('input = Json::Object(); input["action"] = "reload";', "CONFIRMATION_REQUIRED"),
    ('input["confirm"] = "true";', "INVALID_INPUT"),
    ('input["confirm"] = uint(1);', "INVALID_INPUT"),
    ('input["action"] = "other";', "INVALID_INPUT"),
    ('input["action"] = true;', "INVALID_INPUT"),
    ('input = Json::Array();', "INVALID_INPUT"),
])
def test_invalid_input_and_confirmation_never_reload(as_runner, tmp_path, setup, code):
    run_tool(as_runner, tmp_path, '''
        auto input = ReloadInput();
    ''' + setup + '''
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "input refused");
        Check(string(response["code"]) == "''' + code + '''", "specific error");
        Check(app.editor.reloads == 0 && yields == 0 && addRefs == 0, "no native side effects");
    ''')


@pytest.mark.parametrize("setup,code", [
    ("loading = true;", "EDITOR_BUSY"),
    ("shadows = true;", "EDITOR_BUSY"),
    ("crash = true;", "MANIASCRIPT_CRASH"),
    ("@app.editor = null;", "NO_EDITOR"),
    ("@currentMap = null;", "NO_MAP"),
    ("@app = null;", "NO_EDITOR"),
])
def test_guards_run_before_reload(as_runner, tmp_path, setup, code):
    run_tool(as_runner, tmp_path, '''
        auto original = app.editor;
    ''' + setup + '''
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "unsafe context refused");
        Check(string(response["code"]) == "''' + code + '''", "specific error");
        Check(!bool(response["output"]["reloadInvoked"]), "no reload attempted");
        Check(original.reloads == 0 && yields == 0 && addRefs == 0, "guard before call and lease");
        CheckUnverified(response["output"]);
    ''')


@pytest.mark.parametrize("transition", [0, 1])
def test_reload_retains_map_and_resolves_current_editor(as_runner, tmp_path, transition):
    run_tool(as_runner, tmp_path, f"transitions = {transition};\n" + r'''
        auto original = app.editor;
        auto map = currentMap;
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(bool(response["success"]), "invocation observed successfully");
        Check(original.reloads == 1 && yields == 1, "one call and one observation yield");
        auto output = response["output"];
        Check(bool(output["reloadInvoked"]) && bool(output["reloadReturned"]), "invoked and returned");
        Check(bool(output["mapIdentityMatches"]), "retained map identity compared");
        CheckUnverified(output);
        if (transitions == 1) {
            Check(string(output["forcedPluginNames"][uint(0)]) == "fresh-editor", "fresh editor names");
            Check(app.editor.reloads == 0, "replacement editor never reloaded");
        }
        Check(map.refs == 0 && addRefs == 1 && releases == 1, "map released on success");
    ''')


@pytest.mark.parametrize("transition", [2, 3, 4, 8])
def test_context_change_cannot_claim_reload_verified(as_runner, tmp_path, transition):
    run_tool(as_runner, tmp_path, f"transitions = {transition};\n" + r'''
        auto original = app.editor;
        auto map = currentMap;
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "changed context refused");
        Check(string(response["code"]) == "CONTEXT_CHANGED", "identity failure");
        Check(original.reloads == 1, "no retry after context change");
        Check(bool(response["output"]["reloadInvoked"]), "mutation evidence preserved");
        Check(bool(response["output"]["reloadReturned"]), "returned call evidence preserved");
        CheckUnverified(response["output"]);
        if (transitions == 2) {
            Check(currentMap.uid == map.uid, "identical metadata fixture");
            Check(!bool(response["output"]["mapIdentityMatches"]), "identity, not metadata");
        }
        Check(map.refs == 0 && addRefs == 1 && releases == 1, "map released on context failure");
    ''')


@pytest.mark.parametrize("transition", [5, 6, 7])
def test_post_reload_busy_and_crash_observations_stay_unverified(as_runner, tmp_path, transition):
    run_tool(as_runner, tmp_path, f"transitions = {transition};\n" + r'''
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "post reload unsafe observation");
        Check(string(response["code"]) == "RELOAD_UNVERIFIED", "unverified outcome");
        Check(bool(response["output"]["reloadInvoked"]), "invocation evidence");
        CheckUnverified(response["output"]);
        Check(app.editor.reloads == 1 && yields == 1, "no automatic retry");
        Check(currentMap.refs == 0 && addRefs == 1 && releases == 1, "error path releases map");
    ''')


def test_native_exception_preserves_attempt_and_releases_map(as_runner, tmp_path):
    run_tool(as_runner, tmp_path, r'''
        throwReload = true;
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "native exception reported");
        Check(string(response["code"]) == "RELOAD_UNVERIFIED", "outcome unknown");
        Check(bool(response["output"]["reloadInvoked"]), "attempt preserved");
        Check(!bool(response["output"]["reloadReturned"]), "return not fabricated");
        CheckUnverified(response["output"]);
        Check(app.editor.reloads == 1 && yields == 0, "exception does not retry or yield");
        Check(currentMap.refs == 0 && addRefs == 1 && releases == 1, "exception releases map");
    ''')


def test_observation_exception_preserves_return_and_releases_map(as_runner, tmp_path):
    run_tool(as_runner, tmp_path, r'''
        transitions = 9;
        auto input = ReloadInput();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(response["success"]), "observation exception reported");
        Check(string(response["code"]) == "RELOAD_UNVERIFIED", "outcome unknown");
        Check(bool(response["output"]["reloadInvoked"]), "attempt preserved");
        Check(bool(response["output"]["reloadReturned"]), "normal native return preserved");
        CheckUnverified(response["output"]);
        Check(app.editor.reloads == 1 && yields == 1, "one invocation before observation failure");
        Check(currentMap.refs == 0 && addRefs == 1 && releases == 1, "observation exception releases map");
    ''')


def test_status_reports_busy_state_without_mutation(as_runner, tmp_path):
    run_tool(as_runner, tmp_path, r'''
        loading = true; shadows = true; crash = true;
        auto input = Json::Object();
        auto response = TmMcp::ControlEditorScriptPlugins(input);
        Check(bool(response["success"]), "busy status still available");
        auto output = response["output"];
        Check(bool(output["loading"]) && bool(output["calculatingShadows"]) && bool(output["crashDialogDetected"]), "observed flags");
        Check(app.editor.reloads == 0 && yields == 0 && addRefs == 0, "status remains read only");
        CheckUnverified(output);
    ''')


@pytest.mark.parametrize("mode", ["Race", "MapEditor_Test", "MapEditor_Validate", "MapEditor_Playground", "Loading"])
def test_reload_requires_idle_map_editor(as_runner, tmp_path, mode):
    run_tool(as_runner, tmp_path, f'mode = "{mode}"; auto input = ReloadInput();\n' + r'''
        auto v = TmMcp::ControlEditorScriptPlugins(input);
        Check(!bool(v["success"]) && app.editor.reloads == 0, "driving and loading refuse reload");
        Check(addRefs == 0 && releases == 0, "no lease on refused mode");
    ''')
