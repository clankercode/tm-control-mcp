"""Execute the server supervision decision without a socket or live timeout."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_restart_only_after_owned_worker_terminates(as_runner, tmp_path):
    case = tmp_path / "server.as"
    case.write_text('''
void RunTests() {
    Check(!TmMcp::ShouldRestartSocketLoop(false, true, false), "shutdown never restarts");
    Check(!TmMcp::ShouldRestartSocketLoop(true, true, true), "live worker remains owned even during stall");
    Check(TmMcp::ShouldRestartSocketLoop(true, false, false), "missing worker is a visible retry, not a silent orphan");
    Check(TmMcp::ShouldRestartSocketLoop(true, true, false), "terminated worker must be replaced");
}
''')
    result = subprocess.run([str(as_runner), str(ROOT / "src/ServerPolicy.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_startup_and_shutdown_own_supervisor_and_worker():
    text = (ROOT / "src/Server.as").read_text()
    assert "@g_serverWorker = startnew" in text
    assert "@g_serverSupervisor = startnew(CoroutineFunc(SuperviseServerLoop))" in text
    assert "g_serverWorker.IsRunning()" in text
    assert "ShouldRestartSocketLoop(g_running" in text
    body = text[text.index("void SuperviseServerLoop("):text.index("void StartServerAfterDelay(")]
    assert body.index("CloseListener();") < body.index("LaunchServerWorker()")
    launch = text[text.index("bool LaunchServerWorker("):text.index("void SuperviseServerLoop(")]
    assert "catch" in launch
    assert 'g_serverWorkerError = "server worker launch returned no handle"' in launch
    assert "CloseListener();" in launch
    assert "if (!LaunchServerWorker()) sleep(1000);" in body


def test_actual_launcher_handles_success_null_and_exception(as_runner, tmp_path):
    text = (ROOT / "src/Server.as").read_text()
    helper = text[text.index("    bool LaunchServerWorker("):text.index("    void SuperviseServerLoop(")]
    case = tmp_path / "launch.as"
    case.write_text('''
class awaitable { }
funcdef void CoroutineFunc();
int outcome = 0;
awaitable@ startnew(CoroutineFunc@) {
    if (outcome == 1) return null;
    if (outcome == 2) Check(false, "launch fault");
    return awaitable();
}
string getExceptionInfo() { return "launch fault"; }
void warn(const string &in) { }
namespace TmMcp {
    awaitable@ g_serverWorker;
    string g_serverWorkerError;
    bool g_starting = true;
    uint closes = 0;
    void CloseListener() { closes++; }
    void StartServerAfterDelay() { }
''' + helper + '''
}
void RunTests() {
    Check(TmMcp::LaunchServerWorker(), "running handle retained");
    Check(TmMcp::g_serverWorker !is null && TmMcp::closes == 0, "success owns worker");
    outcome = 1;
    Check(!TmMcp::LaunchServerWorker(), "null fails closed");
    Check(TmMcp::closes == 1 && !TmMcp::g_starting && TmMcp::g_serverWorkerError.Length > 0, "null visible terminal");
    outcome = 2;
    Check(!TmMcp::LaunchServerWorker(), "throw fails closed");
    Check(TmMcp::closes == 2 && TmMcp::g_serverWorkerError.Length > 0, "throw visible terminal");
}
''')
    result = subprocess.run([str(as_runner), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
