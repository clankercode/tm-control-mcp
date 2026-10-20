"""Execute the real exchange tracer with a fake file sink; payloads never reach it."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_trace_records_only_bounded_metadata(as_runner, tmp_path):
    fixtures = tmp_path / "fixtures.as"
    fixtures.write_text(r'''
array<string> recorded;
bool S_TmMcpTraceRequests = false;
namespace Time { int64 Stamp = 123; }
namespace IO {
    enum FileMode { Append }
    string FromStorageFolder(const string &in s) { return s; }
    bool FileExists(const string &in) { return false; }
    uint64 FileSize(const string &in) { return 0; }
    void Delete(const string &in) { }
    void Move(const string &in, const string &in) { }
    class File {
        File(const string &in, FileMode) { }
        void WriteLine(const string &in s) { recorded.InsertLast(s); }
        void Close() { }
    }
}
void warn(const string &in s) { recorded.InsertLast(s); }
string getExceptionInfo() { return "fake IO error"; }
''')
    case = tmp_path / "case.as"
    case.write_text(r'''
void RunTests() {
    TmMcpTraceExchange("secret", "another-secret");
    Check(recorded.Length == 0, "disabled trace is silent");
    S_TmMcpTraceRequests = true;
    TmMcpTraceExchange("secret", "another-secret");
    Check(recorded.Length == 1, "one metadata line");
    Check(recorded[0].IndexOf("secret") < 0, "neither payload is logged");
    Check(recorded[0].IndexOf("requestBytes=6 responseBytes=14") >= 0, "sizes retained");
    string big = "x"; for (uint i=0; i<15; i++) big += big;
    TmMcpTraceExchange(big, big);
    Check(recorded[1].Length < 100, "huge payload gives short metadata");
    string bounded = TmMcpTraceOneLine(big);
    Check(bounded.Length < 550 && bounded.SubStr(0, 512).Length == 512, "metadata bound");
    Check(TmMcpTraceOneLine("a\r\nb\nc\rd") == "a\\nb\\nc\\nd", "line injection escaped");
}
''')
    result = subprocess.run([str(as_runner), str(fixtures), str(ROOT / "src/RequestTrace.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_auth_probe_has_no_credential_acquisition_or_value_reads():
    """Negative publication lint complements the live status and rejection probes."""
    source = (ROOT / "src/DevNativeAuthProbe.as").read_text()
    for forbidden in ("Authentication_GetToken(", "Authentication_GetToken_v2(",
                      "Authentication_Token", "Net::", "DecodeBase64", ".Login", ".Value", "trace("):
        assert forbidden not in source
    assert 'string(input["mode"]) != "status"' in source


def _function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


def test_unknown_tool_names_cannot_reach_either_log_sink(as_runner, tmp_path):
    from as_json_mocks import JSON_MOCKS

    # Compile the actual lifecycle/name-admission functions without requiring
    # Openplanet coroutine machinery. The CallTool entry ordering is checked too.
    production = (ROOT / 'src/ToolCalls.as').read_text()
    admission = _function(production, 'Json::Value@ ValidateToolCallName(')
    event = _function(production, 'void ToolCallEvent(')
    call = _function(production, 'Json::Value@ CallTool(')
    assert call.index('ValidateToolCallName(name)') < call.index('SweepToolCalls()')
    mocks = tmp_path / 'mocks.as'
    mocks.write_text(JSON_MOCKS + r'''
array<string> files, logs;
bool S_TmMcpTraceRequests = false;
namespace Time { int64 Stamp = 123; }
namespace IO {
    enum FileMode { Append }
    string FromStorageFolder(const string &in s) { return s; }
    bool FileExists(const string &in) { return false; }
    uint64 FileSize(const string &in) { return 0; }
    void Delete(const string &in) { }
    void Move(const string &in, const string &in) { }
    class File {
        File(const string &in, FileMode) { }
        void WriteLine(const string &in s) { files.InsertLast(s); }
        void Close() { }
    }
}
void trace(const string &in s) { logs.InsertLast(s); }
void warn(const string &in s) { logs.InsertLast(s); }
string getExceptionInfo() { return "IO failure"; }
namespace TmMcp {
    string g_ToolCallInstance = "fixture";
    int FindSchema(const string &in name) { return name == "RegisteredFixture" ? 0 : -1; }
    bool IsToolName(const string &in name) { return name == "GetMode"; }
    Json::Value@ MakeError(const string &in, const string &in code) {
        auto v = Json::Object(); v["success"] = false; v["code"] = code; return v;
    }
}
''')
    funcs = tmp_path / 'functions.as'
    funcs.write_text('namespace TmMcp {\n' + event + '\n' + admission + '\n}\n')
    case = tmp_path / 'case.as'
    case.write_text(r'''
void RunTests() {
    string sentinel = "sentinel-sensitive-name\nforged-line";
    auto invalid = TmMcp::ValidateToolCallName(sentinel);
    Check(invalid !is null && string(invalid["code"]) == "unknown_tool", "unknown refused");
    Check(files.Length == 1 && logs.Length == 1, "fixed refusal reaches both sinks");
    Check(files[0].IndexOf("sentinel") < 0 && logs[0].IndexOf("sentinel") < 0, "no caller text in either sink");
    Check(files[0].IndexOf("<unknown>") >= 0 && logs[0].IndexOf("<unknown>") >= 0, "fixed placeholder");
    Check(TmMcp::ValidateToolCallName("GetMode") is null, "known route alias admitted");
    Check(TmMcp::ValidateToolCallName("RegisteredFixture") is null, "registered tool without route alias admitted");
    Check(files.Length == 1 && logs.Length == 1, "admission has no extra log");
    string huge = "x"; for (uint i=0; i<15; i++) huge += huge;
    TmMcp::ToolCallEvent("first\n" + huge);
    Check(files[1].Length < 600 && logs[1].Length < 600, "both sinks bounded");
    Check(files[1].IndexOf("\n") < 0 && logs[1].IndexOf("\n") < 0, "both sinks escape newlines");
}
''')
    r = subprocess.run([str(as_runner), str(mocks), str(ROOT / 'src/RequestTrace.as'), str(funcs), str(case)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout + r.stderr
