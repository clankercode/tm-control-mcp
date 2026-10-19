"""Execute the production pure policy in stock AngelScript, not a Python port.

Requires a local AngelScript SDK (ANGELSCRIPT_ROOT, default ~/src/angelscript).
The harness supplies Openplanet string aliases and explicit activity/response
fixtures for selected production functions. It does not exercise real Net,
Meta, persistence, coroutine scheduling, or prove in-game compilation/lifecycle.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def as_runner(tmp_path_factory):
    sdk = Path(os.environ.get("ANGELSCRIPT_ROOT", Path.home() / "src/angelscript")) / "sdk"
    lib = sdk / "angelscript/lib/libangelscript.a"
    if not lib.is_file() or not shutil.which("g++"):
        if os.environ.get("TCM_REQUIRE_ANGELSCRIPT") == "1":
            pytest.fail("Required AngelScript SDK static library or g++ is missing")
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


def run_policy(as_runner, tmp_path, body, fixtures=""):
    test = tmp_path / "tests.as"
    test.write_text(fixtures + "\nvoid RunTests() {\n" + body + "\n}")
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


def production_function(name):
    source = (ROOT / "src/PackUpdates.as").read_text()
    match = re.search(r"^    [^\n]* " + name + r"\([^\n]*\) \{.*?^    }", source, re.M | re.S)
    assert match, name
    return match[0]


def test_cache_admission(as_runner, tmp_path):
    # Run real Find/Ensure and the pure eviction selector. Only the registry's
    # plugin activity lookup is replaced; fixtures never decide cache admission.
    fixtures = r'''
    namespace TmMcp {
        const string BRIDGE_UPDATE_URL = "https://bridge.example/latest.txt";
        array<PackUpdateEntry@> g_PackUpdates;
        array<string> activeUrls;
        bool IsPackUpdateActive(const string &in url) {
            return url == BRIDGE_UPDATE_URL || activeUrls.Find(url) >= 0;
        }
    ''' + production_function("FindPackUpdate") + production_function("EnsurePackUpdate") + r'''
    }
    '''
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto bridge = EnsurePackUpdate(BRIDGE_UPDATE_URL);
    // The bridge and 63 historical URLs survive persistence/reload.
    for (uint i = 0; i < UPDATE_CACHE_LIMIT - 1; i++) {
        auto e = EnsurePackUpdate("https://old.example/" + i, true);
        e.lastAttemptAt = 100 + i;
    }
    FindPackUpdate("https://old.example/50").lastAttemptAt = 1;
    string current = "https://current.example/latest.txt";
    activeUrls.InsertLast(current);
    auto admitted = EnsurePackUpdate(current);
    Check(admitted !is null, "full historical cache must admit a current pack");
    Check(g_PackUpdates.Length == UPDATE_CACHE_LIMIT, "eviction keeps capacity bounded");
    Check(FindPackUpdate(BRIDGE_UPDATE_URL) is bridge, "bridge never evicted");
    Check(FindPackUpdate("https://old.example/50") is null, "oldest inactive attempt evicted, not first slot");
    Check(EnsurePackUpdate(current) is admitted, "existing cache identity preserved");

    // Neither current registrations nor requests already in flight may be evicted.
    string protectedUrl = "https://old.example/1";
    activeUrls.InsertLast(protectedUrl);
    auto protectedEntry = FindPackUpdate(protectedUrl);
    auto inFlight = FindPackUpdate("https://old.example/2");
    inFlight.checking = true;
    string second = "https://current.example/second.txt";
    activeUrls.InsertLast(second);
    Check(EnsurePackUpdate(second) !is null, "admit past active and in-flight entries");
    Check(FindPackUpdate(protectedUrl) is protectedEntry, "active cache never evicted");
    Check(FindPackUpdate(inFlight.url) is inFlight, "in-flight cache never evicted");
    Check(FindPackUpdate("https://old.example/0") is null, "next oldest eligible victim");

    Check(EnsurePackUpdate("https://history.example/restored.txt", true) is null,
          "restoration cannot evict at capacity");
    Check(EnsurePackUpdate("https://inactive.example/latest.txt") is null,
          "inactive new registration cannot evict");
    Check(FindPackUpdate(current) is admitted, "history cannot displace current URL");
    // A persisted entry for an already-admitted URL can still be restored.
    Check(EnsurePackUpdate(current, true) is admitted, "restore existing cache entry");

    for (uint i = 0; i < g_PackUpdates.Length; i++) activeUrls.InsertLast(g_PackUpdates[i].url);
    string overflow = "https://current.example/overflow.txt";
    activeUrls.InsertLast(overflow);
    Check(EnsurePackUpdate(overflow) is null, "genuinely full active cache refuses admission");
    Check(g_PackUpdates.Length == UPDATE_CACHE_LIMIT, "full active cache remains bounded");
    Check(FindPackUpdate(BRIDGE_UPDATE_URL) is bridge, "bridge protected at full capacity");

    // Inactive but in-flight entries alone can also make the cache honestly full.
    while (activeUrls.Length > 0) activeUrls.RemoveAt(0);
    activeUrls.InsertLast(overflow);
    for (uint i = 0; i < g_PackUpdates.Length; i++) g_PackUpdates[i].checking = true;
    Check(EnsurePackUpdate(overflow) is null, "all in-flight entries are protected even if inactive");
    Check(FindPackUpdate(BRIDGE_UPDATE_URL) is bridge, "bridge still protected");
    ''', fixtures)


def test_response_acceptance(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    Check(PackUpdateTransferError("connection reset", 200, 5, 5).Length > 0,
          "HTTP 200 with a transfer error is not a success");
    Check(PackUpdateTransferError("", 200, 5, 60).Length > 0, "short known transfer");
    Check(PackUpdateTransferError("", 200, 6, 5).Length > 0, "excess known transfer");
    Check(PackUpdateTransferError("", 200, 5, 1025).Length > 0, "oversized advertised transfer");
    Check(PackUpdateTransferError("", 200, 1025, 0).Length > 0, "oversized unknown-length transfer");
    Check(PackUpdateTransferError("", 503, 5, 5).Length > 0, "HTTP error");
    Check(PackUpdateTransferError("", 200, 5, 5) == "", "complete 200 transfer");
    Check(PackUpdateTransferError("", 206, 5, 5) == "", "complete 206 transfer");
    Check(PackUpdateTransferError("", 200, 5, 0) == "", "unknown-length transfer allowed");
    Check(PackUpdateBodyError(200, "5", "", 5) == "", "matching content length");
    Check(PackUpdateBodyError(200, " 0005 ", "", 5) == "", "valid header whitespace and zero padding");
    Check(PackUpdateBodyError(200, "", "", 5) == "", "chunked response without length");
    Check(PackUpdateBodyError(206, "5", "bytes 0-4/5", 5) == "", "whole ranged body");
    Check(PackUpdateBodyError(206, "5", "bytes 0-4/50", 5).Length > 0, "partial ranged body");
    Check(PackUpdateBodyError(206, "5", "", 5).Length > 0, "missing range");
    Check(PackUpdateBodyError(200, "6", "", 5).Length > 0, "short body with known length");
    Check(PackUpdateBodyError(200, "0", "", 5).Length > 0, "zero known length with body");
    Check(PackUpdateBodyError(200, "5garbage", "", 5).Length > 0, "malformed length");
    Check(PackUpdateBodyError(200, "999999999999999999999999999", "", 5).Length > 0, "length cannot overflow");
    Check(PackUpdateBodyError(200, "1025", "", 1025).Length > 0, "body size bound");
    Check(PackUpdateBodyError(200, "32", "", 5, 32) == "", "encoded length measures wire bytes");
    Check(PackUpdateBodyError(206, "32", "bytes 0-31/32", 5, 32) == "", "encoded range measures wire bytes");
    Check(PackUpdateBodyError(200, "31", "", 5, 32).Length > 0, "encoded header still checked");
    Check(PackUpdateBodyError(200, "32", "", 1025, 32).Length > 0, "decoded body remains bounded");
    ''')


def test_production_response_wiring(as_runner, tmp_path):
    # Execute the exact response-acceptance block from the worker, with a
    # completed request fixture, then the real cache state transition.
    source = production_function("FetchPackUpdate")
    start = source.index("            if (error.Length == 0) {")
    end = source.index("            if (error.Length > 0) g_UpdateRequest.Cancel();", start)
    acceptance = source[start:end]
    fixtures = r'''
    class CompletedRequest {
        string transferError, contentLength, range, encoding, response = "9.0.0";
        int code = 200, reads = 0;
        int64 downloaded = 5, total = 5;
        string Error() { return transferError; }
        int ResponseCode() { return code; }
        int64 ProgressDownload() { return downloaded; }
        int64 ProgressDownloadTotal() { return total; }
        string ResponseHeader(const string &in name) {
            if (name == "Content-Length") return contentLength;
            if (name == "Content-Encoding") return encoding;
            return range;
        }
        string String() { reads++; return response; }
    }
    CompletedRequest@ g_UpdateRequest;
    void Complete(TmMcp::PackUpdateEntry@ e) {
        using namespace TmMcp;
        string error = "", body = "";
    ''' + acceptance + r'''
        FinishPackUpdate(e, 100, body, error);
    }
    '''
    run_policy(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto e = PackUpdateEntry();
    FinishPackUpdate(e, 10, "1.0.0", "");
    @g_UpdateRequest = CompletedRequest();
    g_UpdateRequest.transferError = "connection reset";
    auto empty = PackUpdateEntry(); Complete(empty);
    Check(empty.latestVersion == "" && empty.lastSuccessAt == 0 && empty.error.Length > 0,
          "failed parseable prefix cannot create first success");
    BeginPackUpdate(e, 99); Complete(e);
    Check(g_UpdateRequest.reads == 0, "transfer error rejected before body read");
    Check(e.latestVersion == "1.0.0" && e.lastSuccessAt == 10, "error preserves last success");
    Check(e.error.Length > 0 && e.nextAttemptAt == 100 + UPDATE_RETRY_TTL && !e.checking,
          "transfer error terminates with failure retry");
    Check(!PackUpdateAvailable("1.0.0", e.latestVersion), "partial prefix cannot advertise update");

    @g_UpdateRequest = CompletedRequest(); g_UpdateRequest.total = 50;
    Complete(e);
    Check(g_UpdateRequest.reads == 0 && e.latestVersion == "1.0.0", "short transfer rejected before body read");
    @g_UpdateRequest = CompletedRequest(); g_UpdateRequest.contentLength = "50";
    Complete(e);
    Check(e.error.Length > 0 && e.latestVersion == "1.0.0", "body length check is wired");
    @g_UpdateRequest = CompletedRequest(); g_UpdateRequest.code = 206;
    g_UpdateRequest.range = "bytes 0-4/50";
    Complete(e);
    Check(e.error.Length > 0 && e.latestVersion == "1.0.0", "range completeness check is wired");
    @g_UpdateRequest = CompletedRequest(); g_UpdateRequest.contentLength = "5";
    Complete(e);
    Check(e.error == "" && e.latestVersion == "9.0.0" && e.lastSuccessAt == 100,
          "valid response recovers successfully");
    Check(e.nextAttemptAt == 100 + UPDATE_SUCCESS_TTL, "successful recovery uses success TTL");
    @g_UpdateRequest = CompletedRequest(); g_UpdateRequest.encoding = "gzip";
    g_UpdateRequest.contentLength = "32"; g_UpdateRequest.downloaded = 32; g_UpdateRequest.total = 32;
    Complete(e);
    Check(e.error == "" && e.latestVersion == "9.0.0", "encoded HTTP 200 uses wire length, not decoded length");
    g_UpdateRequest.code = 206; g_UpdateRequest.range = "bytes 0-31/32";
    Complete(e);
    Check(e.error == "", "encoded HTTP 206 uses wire length for range completeness");
    ''', fixtures)
