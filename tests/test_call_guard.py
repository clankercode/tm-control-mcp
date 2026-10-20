"""Execute production guard policy in AngelScript; live probe covers the VM."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_interleaved_completion_and_terminal_policy(as_runner, tmp_path):
    case = tmp_path / 'case.as'
    case.write_text('''
class Owner : TmMcp::IToolCallOwner {
    bool alive = true;
    bool IsRunning() { return alive; }
}
void RunTests() {
    TmMcp::ToolCallRegistry registry;
    auto a = TmMcp::CallLease(); a.name = "ControlPlugin";
    auto b = TmMcp::CallLease(); b.name = "WaitUntil";
    Check(registry.Admit(a), "first starts");
    Check(registry.Admit(b), "independent starts while first yielded");
    registry.Release(a.id);
    auto c = TmMcp::CallLease(); c.name = "ControlPlugin";
    Check(registry.Admit(c), "completed ControlPlugin must not remain reentrant");
    registry.Release(a.id); // late terminal from an old invocation
    Check(registry.Find("ControlPlugin") is c, "late release preserves successor");
    auto recursive = TmMcp::CallLease(); recursive.name = "ControlPlugin";
    Check(!registry.Admit(recursive), "recursive or concurrent duplicate refused");
    Check(registry.Find("WaitUntil") is b, "out-of-order finish preserves second call");
    auto owner = Owner(); @c.owner = owner; c.started = 100; c.budget = 60;
    Check(c.Failure(159) == "", "not expired before deadline");
    Check(c.Failure(160) == "tool_timeout", "deadline inclusive");
    owner.alive = false;
    Check(c.Failure(101) == "tool_terminated", "VM-aborted worker detected before deadline");
    c.finished = true;
    Check(c.Failure(200) == "", "terminal is stable");
    registry.Release(c.id); registry.Release(b.id);
    Check(registry.calls.Length == 0, "all released by identity");
}
''')
    r = subprocess.run([str(as_runner), str(ROOT / 'src/ToolCallPolicy.as'), str(case)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
