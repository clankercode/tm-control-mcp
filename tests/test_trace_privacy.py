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
