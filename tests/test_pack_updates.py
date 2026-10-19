"""Execute the production pure policy in stock AngelScript, not a Python port.

Requires a local AngelScript SDK (ANGELSCRIPT_ROOT, default ~/src/angelscript).
The harness supplies Openplanet string aliases only. It does not emulate Net,
Meta, persistence, coroutine scheduling, or prove in-game compilation/lifecycle.
"""
from pathlib import Path
import os
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def as_runner(tmp_path_factory):
    sdk = Path(os.environ.get("ANGELSCRIPT_ROOT", Path.home() / "src/angelscript")) / "sdk"
    lib = sdk / "angelscript/lib/libangelscript.a"
    if not lib.is_file() or not shutil.which("g++"):
        pytest.skip("AngelScript SDK static library and g++ required; set ANGELSCRIPT_ROOT")
    out = tmp_path_factory.mktemp("pack-update-policy") / "runner"
    addon = sdk / "add_on"
    subprocess.run([
        "g++", "-std=c++17", "-O1", "-pthread",
        f"-I{sdk / 'angelscript/include'}", f"-I{addon / 'scriptstdstring'}",
        f"-I{addon / 'scriptarray'}", str(ROOT / "tests/test_pack_updates_runner.cpp"),
        str(addon / "scriptstdstring/scriptstdstring.cpp"), str(addon / "scriptarray/scriptarray.cpp"),
        str(lib), "-o", str(out),
    ], check=True, capture_output=True, text=True)
    return out


def run_policy(as_runner, tmp_path, body):
    test = tmp_path / "tests.as"
    test.write_text("void RunTests() {\n" + body + "\n}")
    run = subprocess.run([str(as_runner), str(ROOT / "src/PackUpdatePolicy.as"), str(test)], capture_output=True, text=True)
    assert run.returncode == 0, run.stdout + run.stderr


def test_semver(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    string[] valid = {"0.0.0", "v1.2.3", "  v1.2.3-alpha.1+sha.001\n", "1.2.3+123", "1.2.3-0", "99999999999999999999999999.0.0"};
    for (uint i=0; i<valid.Length; i++) Check(ParsePackVersion(valid[i]) !is null, "valid: " + valid[i]);
    string[] invalid = {"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "V1.2.3", "1.2.3-", "1.2.3+", "1.2.3-a..b", "1.2.3-01", "1.2.3+a+b", "1.2.3\n2.3.4", "1.2.3-foo_bar", "-1.2.3"};
    for (uint i=0; i<invalid.Length; i++) Check(ParsePackVersion(invalid[i]) is null, "invalid: " + invalid[i]);
    string[] ordered = {"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0", "99999999999999999999999999.0.0"};
    for (uint i=0; i<ordered.Length; i++) {
        for (uint j=0; j<ordered.Length; j++) {
            Check(PackUpdateAvailable(ordered[i], ordered[j]) == (j > i), "order " + ordered[i] + " / " + ordered[j]);
        }
    }
    Check(!PackUpdateAvailable("1.2.3+a", "v1.2.3+b"), "build ignored");
    Check(!PackUpdateAvailable("invalid", "9.0.0"), "unknown installed");
    Check(!PackUpdateAvailable("1.0.0", "invalid"), "unknown latest");
    Check(PackUpdateAvailable("1.0.0-99999999999999999999", "1.0.0-100000000000000000000"), "huge prerelease");
    ''')


def test_cache_policy(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    string url = "https://author.github.io/pack/latest-version.txt";
    auto e = PackUpdateEntry(); e.url = url;
    Check(PackUpdateStatus(url, "1.0.0", e, true, 100) == "pending", "pending");
    Check(PackUpdateDue(e, 100), "first due");
    BeginPackUpdate(e, 100);
    Check(!PackUpdateDue(e, 100 + UPDATE_RETRY_TTL), "one in flight");
    Check(PackUpdateStatus(url, "1.0.0", e, true, 100) == "checking", "checking");
    FinishPackUpdate(e, 101, "2.0.0", "");
    Check(e.latestVersion == "2.0.0" && e.lastSuccessAt == 101, "success recorded");
    Check(!PackUpdateDue(e, 101 + UPDATE_SUCCESS_TTL - 1), "success ttl");
    Check(PackUpdateDue(e, 101 + UPDATE_SUCCESS_TTL), "success expires");
    Check(PackUpdateStatus(url, "1.0.0", e, true, 102) == "update_available", "available");
    Check(PackUpdateStatus(url, "3.0.0", e, true, 102) == "up_to_date", "no downgrade");
    Check(PackUpdateStatus(url, "bad", e, true, 102) == "installed_version_unknown", "unknown");
    Check(PackUpdateStatus(url, "1.0.0", e, true, 101 + UPDATE_SUCCESS_TTL) == "stale", "expired stale");
    BeginPackUpdate(e, 22000); FinishPackUpdate(e, 22001, "", "HTTP 503");
    Check(e.latestVersion == "2.0.0" && e.lastSuccessAt == 101 && e.error == "HTTP 503", "error retains success");
    Check(PackUpdateStatus(url, "1.0.0", e, true, 22002) == "stale", "failed stale");
    Check(!PackUpdateDue(e, 22001 + UPDATE_RETRY_TTL - 1), "retry backs off");
    Check(PackUpdateDue(e, 22001 + UPDATE_RETRY_TTL), "retry expires");
    FinishPackUpdate(e, 25000, "2.1.0", ""); Check(e.error == "", "recovery clears error");
    FinishPackUpdate(e, 26000, "bad version", ""); Check(e.latestVersion == "2.1.0" && e.error.Length > 0, "invalid retains success");
    Check(PackUpdateStatus(url, "1.0.0", e, false, 27000) == "disabled", "opt out");
    Check(PackUpdateStatus("", "1.0.0", e, true, 27000) == "missing_url", "legacy");
    Check(PackUpdateStatus("http://bad", "1.0.0", e, true, 27000) == "invalid_url", "invalid url");
    auto empty = PackUpdateEntry(); FinishPackUpdate(empty, 10, "", "timeout");
    Check(PackUpdateStatus(url, "1.0.0", empty, true, 11) == "error", "failure without success");
    Check(!PackUpdateAvailable("1.0.0", empty.latestVersion), "failure no spurious update");
    e.nextAttemptAt = 99999999; Check(PackUpdateDue(e, 0), "clock rollback bounded");
    ''')


def test_urls_and_payload_bounds(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    Check(PackUpdateUrlError("https://author.github.io/pack/latest-version.txt") == "", "canonical URL");
    string[] bad = {"", "http://a.io/version.txt", "https://a.io", "https://a.io/", "https://a.io:443/v", "https://u:p@a.io/v", "https://127.0.0.1/v", "https://a.io/v?q=1", "https://a.io/v#frag", "https://a.io/v\nfoo", "https://A.io/v", "https://-a.io/v", "https://a..io/v", "https://a.io/v%20a"};
    for (uint i=0; i<bad.Length; i++) Check(PackUpdateUrlError(bad[i]).Length > 0, "bad URL " + bad[i]);
    string huge = "https://a.io/"; for (uint i=0; i<1024; i++) huge += "a";
    Check(PackUpdateUrlError(huge).Length > 0, "URL cap");
    Check(ParsePackVersion(huge) is null, "body cap");
    string version = "1.0.0-";
    for (uint i=0; i<250; i++) version += "a";
    Check(ParsePackVersion(version) !is null, "version exactly 256 bytes");
    Check(ParsePackVersion(version + "a") is null, "version over 256 bytes");
    string padded = "1.0.0";
    for (uint i=0; i<1019; i++) padded += " ";
    Check(ParsePackVersion(padded) !is null, "body exactly 1024 bytes");
    Check(ParsePackVersion(padded + " ") is null, "body over 1024 bytes");
    Check(CompleteVersionRange("bytes 0-5/6", 6), "complete range");
    Check(!CompleteVersionRange("bytes 0-5/60", 6), "truncated range");
    Check(!CompleteVersionRange("", 6), "missing range");
    Check(!CompleteVersionRange("bytes 0-0/0", 0), "empty range");
    ''')


def test_global_request_spacing(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    Check(PackUpdateStartDelay(false, 0, 0) == 0, "first start is immediate");
    Check(PackUpdateStartDelay(true, 1000, 1000) == 2000, "no burst in same tick");
    Check(PackUpdateStartDelay(true, 1000, 2999) == 1, "spacing before boundary");
    Check(PackUpdateStartDelay(true, 1000, 3000) == 0, "spacing at boundary");
    Check(PackUpdateStartDelay(true, 1000, 3001) == 0, "spacing past boundary");
    Check(PackUpdateStartDelay(true, 1000, 0) == 2000, "clock rollback stays bounded");
    ''')
