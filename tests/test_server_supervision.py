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


def test_rebind_only_when_the_wanted_endpoint_changes(as_runner, tmp_path):
    """2026-11-17: comparing bound with wanted re-listened every loop pass whenever they differ for
    the listener's whole life (a port.override, or a fallback port because the wanted one was busy)."""
    case = tmp_path / "rebind.as"
    case.write_text('''
void RunTests() {
    string h = "127.0.0.1";
    Check(!TmMcp::ShouldRebindListener(false, "", h, 0, 30006), "not listening: nothing to rebind");
    Check(!TmMcp::ShouldRebindListener(true, h, h, 30006, 30006), "plain setting, unchanged");
    Check(!TmMcp::ShouldRebindListener(true, h, h, 30400, 30400), "override bound and still wanted");
    Check(!TmMcp::ShouldRebindListener(true, h, h, 30400, 30400), "bound a fallback (30401) while 30400 is still wanted");
    Check(TmMcp::ShouldRebindListener(true, h, h, 30006, 30400), "setting or override changed");
    Check(TmMcp::ShouldRebindListener(true, h, h, 30400, 30006), "override removed");
    Check(TmMcp::ShouldRebindListener(true, h, "0.0.0.0", 30006, 30006), "host changed");
}
''')
    result = subprocess.run([str(as_runner), str(ROOT / "src/ServerPolicy.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_listener_loop_never_compares_bound_port_with_wanted_port():
    text = (ROOT / "src/Server.as").read_text()
    loop = text[text.index("void ServerLoop("):text.index("int TmMcpResolveWantedPort(")]
    assert "ShouldRebindListener(g_listening, g_boundHost, S_TmMcpHost, g_wantedPortAtBind, TmMcpWantedPort())" in loop
    assert "g_boundPort !=" not in loop and "g_boundPort ==" not in loop
    listen = text[text.index("bool EnsureListening("):]
    bound = listen[listen.index("g_boundPort = boundPort;"):]
    assert bound.index("g_wantedPortAtBind = wantPort;") < bound.index("trace(")
    close = text[text.index("void CloseListener("):text.index("void CloseListener(") + 400]
    assert "g_wantedPortAtBind = 0;" in close

