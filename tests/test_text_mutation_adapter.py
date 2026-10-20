"""Execute real writer adapters with nod setters/readback faults and mode fixtures."""
from pathlib import Path
import subprocess

import pytest
from test_pack_updates import as_runner
from as_json_mocks import JSON_MOCKS

ROOT = Path(__file__).resolve().parents[1]
MOCKS = JSON_MOCKS + r'''
string mode = "MapEditor";
bool loading = false, shadows = false, crash = false;
bool readFailure = false, writeFailure = false, ignoreWrite = false, corruptReadback = false;
uint writes = 0;
class CTrackMania { }
CTrackMania@ GetApp() { return null; }
class CSystemFidFile { }
class CPlugFileTextScript {
    string text = "abc abc";
    string get_Text() property {
        if (readFailure || (writes > 0 && corruptReadback)) Check(false, "read fault");
        return text;
    }
    void set_Text(const string &in value) property {
        writes++;
        if (writeFailure) Check(false, "write fault");
        if (!ignoreWrite) text = value;
    }
}
class CGameUILayer {
    CPlugFileTextScript@ script = CPlugFileTextScript();
    string get_ManialinkPageUtf8() property { return script.Text; }
    void set_ManialinkPageUtf8(const string &in value) property { script.Text = value; }
}
class Menu { array<CGameUILayer@> UILayers = {CGameUILayer()}; }
Menu@ menu = Menu();
CPlugFileTextScript@ script = CPlugFileTextScript();
namespace Math { double Floor(double x) { return double(int(x)); } }
namespace TmMcp {
    string DetectGameModeName() { return mode; }
    bool IsLoadingLike(CTrackMania@) { return loading; }
    bool DetectCalculatingShadows() { return shadows; }
    Json::Value ManiaScriptDiagnostics() { auto v = Json::Object(); v["crashDialogDetected"] = crash; return v; }
    Menu@ _GetMenuApp() { return menu; }
    Json::Value@ MakeError(const string &in message, const string &in code) {
        auto v = Json::Object(); v["success"] = false; v["code"] = code; return v;
    }
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
    Json::Value@ FidsNeedFile(Json::Value &in, const string &in, CSystemFidFile@ &out file) {
        @file = CSystemFidFile(); return null;
    }
    CPlugFileTextScript@ FidsNeedTextScript(CSystemFidFile@, string &out error) { return script; }
}
Json::Value Input() {
    auto v = Json::Object(); v["confirm"] = true; v["find"] = "abc"; v["replace"] = "x";
    v["path"] = "Scripts/EditorPlugins/Example.Script.txt"; v["drive"] = "user";
    v["layerIndex"] = uint(0); return v;
}
'''


def run(as_runner, tmp_path, body):
    mocks, case = tmp_path / "mocks.as", tmp_path / "case.as"
    mocks.write_text(MOCKS)
    case.write_text("void RunTests() {\n" + body + "\n}")
    r = subprocess.run([str(as_runner), str(mocks), str(ROOT / "src/TextMutationPolicy.as"), str(ROOT / "src/TextMutation.as"), str(case)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("page", [False, True])
def test_assignment_and_noop(as_runner, tmp_path, page):
    tool = "PatchLayerXml" if page else "FidsActionSetText"
    mode = "Menu" if page else "MapEditor"
    run(as_runner, tmp_path, f'mode = "{mode}";\nauto input = Input();\n' + f'auto v = TmMcp::{tool}(input);\n' + r'''
    Check(bool(v["success"]) && writes == 1, "one assignment");
    Check(bool(v["output"]["written"]) && bool(v["output"]["readbackMatches"]), "assignment verified");
    input["find"] = "absent";
    ''' + f'@v = TmMcp::{tool}(input);\n' + r'''
    Check(bool(v["success"]) && writes == 1 && !bool(v["output"]["written"]), "no match avoids assignment");
    ''')


@pytest.mark.parametrize("page", [False, True])
@pytest.mark.parametrize("fault", ["ignoreWrite", "corruptReadback"])
def test_readback_failure_is_error(as_runner, tmp_path, page, fault):
    tool = "PatchLayerXml" if page else "FidsActionSetText"
    mode = "Menu" if page else "MapEditor"
    run(as_runner, tmp_path, f'mode = "{mode}"; {fault} = true; auto input = Input();\nauto v = TmMcp::{tool}(input);\n' + r'''
    Check(!bool(v["success"]) && writes == 1, "unverified assignment is error");
    Check(string(v["code"]) == "READBACK_UNCONFIRMED", "no success on readback fault");
    Check(bool(v["output"]["written"]) && !bool(v["output"]["readbackMatches"]), "attempt is preserved");
    ''')


@pytest.mark.parametrize("state", ["Race", "MapEditor_Test", "MapEditor_Validate", "Loading"])
def test_driving_and_loading_refuse_all_writes(as_runner, tmp_path, state):
    run(as_runner, tmp_path, f'mode = "{state}"; auto input = Input();\n' + r'''
    auto a = TmMcp::FidsActionSetText(input); auto b = TmMcp::PatchLayerXml(input);
    Check(!bool(a["success"]) && !bool(b["success"]) && writes == 0, "no writes in driving sessions");
    ''')


def test_confirmation_types_scope_and_faults(as_runner, tmp_path):
    run(as_runner, tmp_path, r'''
    auto input = Input(); input["confirm"] = "true";
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "typed confirmation");
    input["confirm"] = true; input["drive"] = "fake";
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "native game/title scripts rejected");
    input["drive"] = "user"; input["path"] = "Scripts/Modes/Race.Script.txt";
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "race script rejected");
    input["path"] = "Scripts/EditorPlugins/Example.Script.txt"; crash = true;
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "crash rejected");
    crash = false; shadows = true;
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "shadow compute rejected");
    shadows = false; readFailure = true;
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]), "read failure rejected");
    Check(writes == 0, "guards and read failure never assign");
    readFailure = false; writeFailure = true;
    Check(!bool(TmMcp::FidsActionSetText(input)["success"]) && writes == 1, "setter fault is error");
    ''')
