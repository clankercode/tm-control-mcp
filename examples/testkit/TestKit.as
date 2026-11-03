#if DEV
// TestKit: load-time and socket-driven tests, without a plugin dependency.
// Native [Test] functions only run when the Openplanet UI runner is triggered.
// Copy this file to src/TestKit.as, convert tests with gen_registry.py --rewrite,
// and call TestKit::RunSelfChecks("your-plugin-id") from Main() under #if DEV.
// One generated native adapter drives the same registry through CtxSink.
//
// Marker contract (counts are TESTS, not assertions; one terminal per test):
// SELFCHECK BEGIN: <suite>, N registered
// SELFCHECK PASS: <suite> / <qualified test name>
// SELFCHECK FAIL: <suite> / <qualified test name> / <exception text>
// SELFCHECK SUITE: <suite>, N passed, M failed
// Newlines in exception text are escaped. Assertion failure aborts that test;
// RunSuite catches it and continues. A test with no assertions can still pass.
// Keep tests synchronous and reset any production state they mutate.
// Adapted from XertroV's Dips++ and MapTogether TestKit pattern (CC0/Unlicense).
// API signatures verified against OpenplanetCore.json 1.29.14, Tests::Context.
namespace TestKit {
    interface Sink {
        void Check(bool ok, const string &in msg);
    }

    // Borrow the native context only for this synchronous aggregate invocation.
    class CtxSink : Sink {
        private Tests::Context@ ctx;
        CtxSink(Tests::Context@ nativeCtx) { @ctx = nativeCtx; }
        void Check(bool ok, const string &in msg) { ctx.AssertTrue(ok, msg); }
    }

    string OneLine(const string &in text) {
        return text.Replace("\r", "\\r").Replace("\n", "\\n");
    }

    class LogSink : Sink {
        string suite;
        uint passed = 0;
        uint failed = 0;
        string[] failures;
        LogSink(const string &in suiteName) { suite = suiteName; }
        void Check(bool ok, const string &in msg) {
            string line = OneLine(msg);
            if (ok) {
                passed++;
                print("SELFCHECK PASS: " + suite + " / " + line);
            } else {
                failed++;
                failures.InsertLast(line);
                warn("SELFCHECK FAIL: " + suite + " / " + line);
            }
        }
        void Report() {
            print("SELFCHECK SUITE: " + suite + ", " + passed + " passed, " + failed + " failed");
        }
    }

    // Compatibility surface: every Tests::Context overload, actual then expected.
    // Assertions throw at the first failure, including an empty-message assertion.
    class Ctx {
        private void Require(bool ok, const string &in message, const string &in detail) {
            if (!ok) throw(message.Length > 0 ? message + " (" + detail + ")" : detail);
        }
        void AssertTrue(bool condition, const string &in message = "") {
            Require(condition, message, "AssertTrue failed");
        }
        void AssertFalse(bool condition, const string &in message = "") {
            Require(!condition, message, "AssertFalse failed");
        }
        void AssertNull(ref value, const string &in message = "") {
            Require(value is null, message, "AssertNull failed");
        }
        void AssertNotNull(ref value, const string &in message = "") {
            Require(value !is null, message, "AssertNotNull failed");
        }
        void AssertSame(int8 actual, int8 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(int16 actual, int16 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(int actual, int expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(int64 actual, int64 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(uint8 actual, uint8 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(uint16 actual, uint16 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(uint actual, uint expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(uint64 actual, uint64 expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(float actual, float expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSameApprox(float actual, float expected, const string &in message = "") {
            Require(Approx(actual, expected), message, "AssertSameApprox: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(double actual, double expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertSameApprox(double actual, double expected, const string &in message = "") {
            Require(Approx(actual, expected), message, "AssertSameApprox: actual=" + actual + ", expected=" + expected);
        }
        void AssertSame(const string &in actual, const string &in expected, const string &in message = "") {
            Require(actual == expected, message, "AssertSame: actual=" + actual + ", expected=" + expected);
        }
        void AssertNotSame(int8 actual, int8 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(int16 actual, int16 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(int actual, int notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(int64 actual, int64 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(uint8 actual, uint8 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(uint16 actual, uint16 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(uint actual, uint notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(uint64 actual, uint64 notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(float actual, float notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSameApprox(float actual, float notExpected, const string &in message = "") {
            Require(!Approx(actual, notExpected), message, "AssertNotSameApprox: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(double actual, double notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSameApprox(double actual, double notExpected, const string &in message = "") {
            Require(!Approx(actual, notExpected), message, "AssertNotSameApprox: actual=" + actual + ", notExpected=" + notExpected);
        }
        void AssertNotSame(const string &in actual, const string &in notExpected, const string &in message = "") {
            Require(actual != notExpected, message, "AssertNotSame: actual=" + actual + ", notExpected=" + notExpected);
        }
    }

    // Explicit absolute tolerance; native docs expose no tolerance guarantee.
    // NaN is never approximately equal; equal signed infinities compare equal.
    bool Approx(float a, float b) { return a == b || Math::Abs(a - b) <= 0.00001f; }
    bool Approx(double a, double b) { return a == b || Math::Abs(a - b) <= 0.000000001; }

    funcdef void TestFn(Ctx@ ctx);
    class TestEntry {
        string name;
        TestFn@ fn;
        TestEntry(const string &in n, TestFn@ f) { name = n; @fn = f; }
    }
    TestEntry@[] g_registry;

    void Reg(const string &in name, TestFn@ fn) {
        if (fn is null || name.Length == 0) throw("invalid TestKit registration");
        for (uint i = 0; i < g_registry.Length; i++) {
            if (g_registry[i].name == name) throw("duplicate TestKit test: " + name);
        }
        g_registry.InsertLast(TestEntry(name, fn));
    }

    // Also accepts a local fixture list so the harness can test exception capture
    // without mutating the real registry. Sink calls sit outside the test catch:
    // an infrastructure/native-sink error must never become a duplicate verdict.
    void RunSuite(TestEntry@[]@ entries, Sink@ sink) {
        for (uint i = 0; i < entries.Length; i++) {
            bool ok = true;
            string message = entries[i].name;
            try { entries[i].fn(Ctx()); }
            catch {
                ok = false;
                message += " / " + getExceptionInfo();
            }
            sink.Check(ok, message);
        }
    }

    void RunAll(Sink@ sink) {
        RegisterAll(); // src/_TestRegistry.as, generated by gen_registry.py
        // Snapshot so accidental registration by a test cannot extend this run.
        auto entries = g_registry;
        RunSuite(entries, sink);
    }

    LogSink@ RunAll(const string &in suite) {
        if (suite.Length == 0 || suite.Contains("\n") || suite.Contains("\r")
            || suite.Contains(",") || suite.Contains(" / ")) throw("invalid TestKit suite name");
        RegisterAll();
        print("SELFCHECK BEGIN: " + suite + ", " + g_registry.Length + " registered");
        auto sink = LogSink(suite);
        RunAll(sink);
        sink.Report();
        return sink;
    }

    Json::Value@ RunSelfChecks(const string &in suite) {
        auto sink = RunAll(suite);
        auto report = Json::Object();
        report["suite"] = suite;
        report["registered"] = int(g_registry.Length);
        report["passed"] = int(sink.passed);
        report["failed"] = int(sink.failed);
        auto failures = Json::Array();
        for (uint i = 0; i < sink.failures.Length; i++) failures.Add(sink.failures[i]);
        report["failures"] = failures;
        return report;
    }
}
#endif
