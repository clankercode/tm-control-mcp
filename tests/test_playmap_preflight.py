"""Bounded raw-file checks run without instantiating game map/item nodes."""
from pathlib import Path
import subprocess
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]


def test_gbx_envelope_checks_never_claim_embedded_content_safety(as_runner, tmp_path):
    case = tmp_path / "map.as"
    case.write_text('''
void RunTests() {
    using namespace TmMcp;
    string header = "GBX";
    uint8[] rest = {6, 0, 66, 85, 67, 82, 0, 48, 4, 3, 4, 0, 0, 0, 0, 0, 0, 0};
    for (uint i=0; i<rest.Length; i++) header += " ";
    for (uint i=0; i<rest.Length; i++) header[3+i] = rest[i];
    Check(PlayMapEnvelopeState(header, 100) == "envelope_only", "plausible envelope does not certify items");
    Check(PlayMapEnvelopeState(header, 20) == "invalid", "truncated declared header");
    Check(PlayMapEnvelopeState("not a map", 100) == "invalid", "wrong file magic");
    Check(PlayMapEnvelopeState("GBX", 3) == "invalid", "truncated prefix");
    header[3] = 7;
    Check(PlayMapEnvelopeState(header, 100) == "unknown_version", "unknown format is not misclassified");
    header[3] = 6; header[13] = 255; header[14] = 255; header[15] = 255; header[16] = 255;
    Check(PlayMapEnvelopeState(header, 100) == "invalid", "declared size exceeds file without overflow");
}
''')
    result = subprocess.run([str(as_runner), str(ROOT / "src/PlayMapPreflightPolicy.as"), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


def test_preflight_precedes_scheduling_and_native_loading():
    text = (ROOT / "src/McpTools.as").read_text()
    body = text[text.index("Json::Value@ PlayMap("):text.index("Json::Value@ GetMapInfo(")]
    assert body.index("PlayMapPreflight(path)") < body.index("startnew(")
    assert 'output["preflight"]' in body
    preflight = (ROOT / "src/PlayMapPreflight.as").read_text()
    assert "Fids::Preload" not in preflight
    assert "f.Read(21)" in preflight


def test_resolver_ignores_working_directory_decoy(as_runner, tmp_path):
    text = (ROOT / "src/PlayMapPreflight.as").read_text()
    resolver = text[text.index("    bool PlayMapPathIsAbsolute("):text.index("    Json::Value PlayMapPreflight(")]
    case = tmp_path / "paths.as"
    case.write_text('''
class Fid {
    string FullFileName = "C:/Maps/Example.Map.Gbx";
    bool OSCheckIfExists() { return true; }
}
bool fidFound = true, fallbackFound = true;
namespace Fids {
    Fid@ GetUser(const string &in path) { return fidFound ? Fid() : null; }
}
namespace IO {
    bool FileExists(const string &in path) {
        // The decoy exists too; only the user's actual map may be selected.
        return path == "Example.Map.Gbx" || path == "C:/Maps/Example.Map.Gbx"
            || (fallbackFound && path == "C:/User/Maps/Example.Map.Gbx");
    }
    string FromUserGameFolder(const string &in relative) { return "C:/User/" + relative; }
}
namespace TmMcp {
''' + resolver + '''
}
void RunTests() {
    Check(TmMcp::ResolvePlayMapLocalPath("Example.Map.Gbx") == "C:/Maps/Example.Map.Gbx", "fid target wins over working-directory decoy");
    fidFound = false;
    Check(TmMcp::ResolvePlayMapLocalPath("Example.Map.Gbx") == "C:/User/Maps/Example.Map.Gbx", "checked user-map fallback");
    fallbackFound = false;
    Check(TmMcp::ResolvePlayMapLocalPath("Example.Map.Gbx") == "", "decoy is not an unresolved target fallback");
    Check(TmMcp::ResolvePlayMapLocalPath("C:/Maps/Example.Map.Gbx") == "C:/Maps/Example.Map.Gbx", "explicit absolute path");
}
''')
    result = subprocess.run([str(as_runner), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
