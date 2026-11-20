"""Execute the production freshness predicate in AngelScript."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_capture_requires_new_file_metadata(as_runner, tmp_path):
    case = tmp_path / "capture.as"
    case.write_text('''
void RunTests() {
    using namespace TmMcp;
    Check(!ScreenshotFileChanged(true, 100, 123, true, 100, 123), "queued path with stale file is not a capture");
    Check(ScreenshotFileChanged(false, 0, 0, true, 100, 123), "new nonempty file");
    Check(ScreenshotFileChanged(true, 100, 123, true, 100, 124), "same slot rewritten at same size");
    Check(ScreenshotFileChanged(true, 100, 123, true, 101, 123), "size changes within timestamp precision");
    Check(!ScreenshotFileChanged(false, 0, 0, false, 0, 0), "missing output");
    Check(!ScreenshotFileChanged(true, 100, 123, true, 0, 124), "empty output");
}
''')
    result = subprocess.run([str(as_runner), str(ROOT / "src/ScreenshotPolicy.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_live_adapter_snapshots_before_capture_and_uses_metadata():
    text = (ROOT / "src/McpTools.as").read_text()
    body = text[text.index("Json::Value@ TakeScreenshot("):text.index("Json::Value@ GetBlocks(")]
    assert body.index("SnapshotScreenshotFolder(") < body.index("vp.ScreenShotDoCaptureWebp()")
    assert "ScreenshotFileChanged(existed, oldSize, oldModified" in body
    assert "candidate != fullNameBefore" not in body
    assert 'output["slotsFull"] = slotsFull' in body
