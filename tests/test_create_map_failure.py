"""A failed menu click chain must remain a failed public tool result."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner
from as_json_mocks import JSON_MOCKS

ROOT = Path(__file__).resolve().parents[1]


def test_create_map_preserves_semantic_failure_and_diagnostics():
    text = (ROOT / "src/ManialinkIntrospection.as").read_text()
    body = text[text.index("Json::Value@ CreateMapViaMenu("):text.index("// Invoke CControlBase::OnAction()", text.index("Json::Value@ CreateMapViaMenu("))]
    assert "return MakeSuccess(" not in body
    assert "return CreateMapMenuResult(rv);" in body
    assert '"CREATE_MAP_FAILED"' in text
    assert 'result["output"] = output;' in text
    assert "EditNewMap" in text


def test_actual_result_adapter_preserves_payload_and_failure(as_runner, tmp_path):
    text = (ROOT / "src/ManialinkIntrospection.as").read_text()
    adapter = text[text.index("    Json::Value@ CreateMapMenuResult("):text.index("    Json::Value@ CreateMapViaMenu(")]
    mocks = tmp_path / "adapter.as"
    mocks.write_text(JSON_MOCKS + '''
namespace TmMcp {
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
    Json::Value@ MakeError(const string &in error, const string &in code, bool retryable, const string &in mode, const string &in hint) {
        auto v = Json::Object(); v["success"] = false; v["code"] = code; return v;
    }
''' + adapter + '''
}
void RunTests() {
    auto output = Json::Object(); output["ok"] = false; output["failedAt"] = "button-create";
    output["expectedFrame"] = "frame-create-type"; output["elapsedMs"] = uint(1500);
    auto result = TmMcp::CreateMapMenuResult(output);
    Check(!bool(result["success"]), "semantic failure reaches public result");
    Check(string(result["code"]) == "CREATE_MAP_FAILED", "structured error");
    Check(string(result["output"]["expectedFrame"]) == "frame-create-type", "diagnostics retained");
    output["ok"] = true;
    @result = TmMcp::CreateMapMenuResult(output);
    Check(bool(result["success"]) && bool(result["output"]["ok"]), "success preserved");
}
''')
    result = subprocess.run([str(as_runner), str(mocks)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
