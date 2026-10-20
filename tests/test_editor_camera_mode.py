"""Execute the shipped edit-camera mode policy, plus check its mutation call sites."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_shipped_camera_mode_policy(tmp_path):
    source = (ROOT / 'src/EditorCameraMode.as').read_text()
    start = source.index('string EditorCameraBlockReason(')
    end = source.index('\n    }', start) + 6
    policy = source[start:end].replace('const string &in', 'const string&')
    program = '''#include <string>
#include <cassert>
using std::string;
''' + policy + '''
int main() {
    assert(EditorCameraBlockReason("MapEditor").empty());
    assert(EditorCameraBlockReason("MapEditor_Test").find("test mode") != string::npos);
    assert(EditorCameraBlockReason("MapEditor_Validate").find("validation") != string::npos);
    assert(EditorCameraBlockReason("MapEditor_Playground").find("playground") != string::npos);
    assert(!EditorCameraBlockReason("Race").empty());
    assert(!EditorCameraBlockReason("Menu").empty());
}
'''
    cpp = tmp_path / 'policy.cpp'
    cpp.write_text(program)
    exe = tmp_path / 'policy'
    subprocess.run(['g++', '-std=c++17', str(cpp), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)


def test_mutations_guard_before_writes_and_reads_report_context():
    text = (ROOT / 'src/McpTools.as').read_text()
    start = text.index('Json::Value@ SetEditorCamera(')
    body = text[start:text.index('Json::Value@ ControlCamera(', start)]
    assert body.index('EditorCameraModeError(editor)') < body.index('pmt.CameraTargetPosition =')
    start = text.index('Json::Value@ ControlCamera(')
    body = text[start:text.index('void RestoreFocusCam(', start)]
    assert body.index('EditorCameraModeError(editor)') < body.index('camera.CenterOnCursor')
    assert 'AddEditorCameraContext(output, editor);' in text
    readiness = (ROOT / 'src/Readiness.as').read_text()
    assert 'EditorCameraBlockReason(mode)' in readiness
    assert 'checks["isTesting"]' in readiness
