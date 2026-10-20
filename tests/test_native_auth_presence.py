"""Execute the availability-only probe with credential getters that fail if touched."""
from pathlib import Path
import subprocess

from test_pack_updates import as_runner
from as_json_mocks import JSON_MOCKS

ROOT = Path(__file__).resolve().parents[1]
MOCKS = JSON_MOCKS + r'''
uint observed = 0;
class NativeAPI {
    bool get_Authentication_GetTokenResponseReceived() property { observed++; return true; }
    int get_Authentication_ErrorCode() property { observed++; return 0; }
    array<int> MasterServer_MSTaskResults = {1,2};
    string get_Authentication_Token() property { Check(false, "credential read forbidden"); return ""; }
    void Authentication_GetToken() { Check(false, "credential acquisition forbidden"); }
    void Authentication_GetToken_v2() { Check(false, "credential acquisition forbidden"); }
}
class User { }
class Handler { User@ LocalUser = User(); }
class Menu { Handler@ ManialinkScriptHandlerMenus = Handler(); }
class CTrackMania { NativeAPI@ ManiaPlanetScriptAPI = NativeAPI(); Menu@ MenuManager = Menu(); }
CTrackMania@ app = CTrackMania();
CTrackMania@ GetApp() { return app; }
namespace TmMcp {
    Json::Value@ MakeError(const string &in, const string &in code) {
        auto v = Json::Object(); v["success"] = false; v["code"] = code; return v;
    }
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
}
'''


def test_presence_only_and_removed_modes(as_runner, tmp_path):
    mocks, source, case = (tmp_path / x for x in ("mocks.as", "source.as", "case.as"))
    mocks.write_text(MOCKS)
    source.write_text((ROOT / "src/DevNativeAuthProbe.as").read_text().replace("#if DEV", "").replace("#endif", ""))
    case.write_text(r'''
void RunTests() {
    auto input = Json::Object();
    auto v = TmMcp::RunDevNativeAuthProbe(input);
    Check(bool(v["success"]), "availability observation");
    Check(bool(v["output"]["apiAvailable"]) && bool(v["output"]["menuLocalUserPresent"]), "availability booleans");
    Check(!bool(v["output"]["credentialValuesRead"]) && observed == 2, "safe getters only");
    Check(uint(v["output"]["taskCount"]) == 2, "count without task values");
    input["mode"] = "legacy";
    Check(!bool(TmMcp::RunDevNativeAuthProbe(input)["success"]) && observed == 2, "legacy refused before any access");
    input["mode"] = "v2";
    Check(!bool(TmMcp::RunDevNativeAuthProbe(input)["success"]) && observed == 2, "v2 refused before any access");
    input["mode"] = "status"; input["loopbackVerifier"] = "valid";
    Check(!bool(TmMcp::RunDevNativeAuthProbe(input)["success"]) && observed == 2, "verifier options refused");
    auto empty = Json::Object(); @app = null;
    @v = TmMcp::RunDevNativeAuthProbe(empty);
    Check(bool(v["success"]) && !bool(v["output"]["apiAvailable"]), "null app safely observed");
}
''')
    r = subprocess.run([str(as_runner), str(mocks), str(source), str(case)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr
