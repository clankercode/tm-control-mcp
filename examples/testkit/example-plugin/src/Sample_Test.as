#if DEV
namespace Tests {
    // [TestKit]
    void BooleanAndString(TestKit::Ctx@ ctx) {
        ctx.AssertTrue(true);
        ctx.AssertFalse(false, "false condition");
        ctx.AssertSame("actual", "actual");
        ctx.AssertNotSame("actual", "other", "strings differ");
    }

    // All native integer widths, signedness, and float/double overloads.
    // [TestKit]
    void NumericOverloads(TestKit::Ctx@ ctx) {
        ctx.AssertSame(int8(7), int8(7));
        ctx.AssertNotSame(int8(7), int8(8));
        ctx.AssertSame(int16(7), int16(7));
        ctx.AssertNotSame(int16(7), int16(8));
        ctx.AssertSame(int(7), int(7));
        ctx.AssertNotSame(int(7), int(8));
        ctx.AssertSame(int64(7), int64(7));
        ctx.AssertNotSame(int64(7), int64(8));
        ctx.AssertSame(uint8(7), uint8(7));
        ctx.AssertNotSame(uint8(7), uint8(8));
        ctx.AssertSame(uint16(7), uint16(7));
        ctx.AssertNotSame(uint16(7), uint16(8));
        ctx.AssertSame(uint(7), uint(7));
        ctx.AssertNotSame(uint(7), uint(8));
        ctx.AssertSame(uint64(7), uint64(7));
        ctx.AssertNotSame(uint64(7), uint64(8));
        ctx.AssertSame(float(7), float(7));
        ctx.AssertNotSame(float(7), float(8));
        ctx.AssertSame(double(7), double(7));
        ctx.AssertNotSame(double(7), double(8));
        ctx.AssertSame(int64(-9223372036854775807), int64(-9223372036854775807));
        ctx.AssertSame(uint64(18446744073709551615), uint64(18446744073709551615));
        ctx.AssertNotSame(uint64(18446744073709551615), uint64(18446744073709551614));
        ctx.AssertSameApprox(1.0f, 1.000001f);
        ctx.AssertNotSameApprox(1.0f, 1.01f);
        ctx.AssertSameApprox(double(1), double(1) + double(0.0000000001));
        ctx.AssertNotSameApprox(double(1), double(1.01));
        ctx.AssertTrue(TestKit::Approx(Math::PosInf, Math::PosInf));
        ctx.AssertFalse(TestKit::Approx(Math::PosInf, Math::NegInf));
        ctx.AssertFalse(TestKit::Approx(Math::PosInf - Math::PosInf, 0.0f), "NaN differs");
    }

    void CheckDoubleApproxBoundary(TestKit::Ctx@ ctx, double actual, double expected, bool within) {
        bool sameThrew = false;
        bool notSameThrew = false;
        try { ctx.AssertSameApprox(actual, expected); }
        catch { sameThrew = true; }
        try { ctx.AssertNotSameApprox(actual, expected); }
        catch { notSameThrew = true; }
        ctx.AssertTrue(sameThrew == !within, "SameApprox double boundary: " + actual + ", " + expected);
        ctx.AssertTrue(notSameThrew == within, "NotSameApprox double boundary: " + actual + ", " + expected);
    }

    // Both assertion verdicts at each side of the inclusive double tolerance.
    // [TestKit]
    void DoubleApproxBoundaries(TestKit::Ctx@ ctx) {
        double[] deltas = {double(0.000000000999999995), double(0.000000001), double(0.000000001000000005)};
        for (uint i = 0; i < deltas.Length; i++) {
            bool within = i < 2;
            CheckDoubleApproxBoundary(ctx, deltas[i], double(0), within);
            CheckDoubleApproxBoundary(ctx, -deltas[i], double(0), within);
            CheckDoubleApproxBoundary(ctx, double(0), deltas[i], within);
            CheckDoubleApproxBoundary(ctx, double(0), -deltas[i], within);
        }
        double inf = double(Math::PosInf);
        double nan = double(Math::PosInf - Math::PosInf);
        CheckDoubleApproxBoundary(ctx, inf, inf, true);
        CheckDoubleApproxBoundary(ctx, -inf, -inf, true);
        CheckDoubleApproxBoundary(ctx, inf, -inf, false);
        CheckDoubleApproxBoundary(ctx, inf, double(0), false);
        CheckDoubleApproxBoundary(ctx, nan, double(0), false);
        CheckDoubleApproxBoundary(ctx, nan, nan, false);
    }

    class SampleObject {}
    // [TestKit]
    void HandleAssertions(TestKit::Ctx@ ctx) {
        SampleObject@ missing;
        auto present = SampleObject();
        ctx.AssertNull(missing);
        ctx.AssertNotNull(present, "object allocated");
        ctx.AssertNull(null);
    }

    class RecordingSink : TestKit::Sink {
        uint passed = 0;
        uint failed = 0;
        string message;
        void Check(bool ok, const string &in msg) {
            if (ok) passed++; else failed++;
            if (!ok) message = msg;
        }
    }

    void Throws(TestKit::Ctx@ ctx) { ctx.AssertTrue(false, "fixture exception"); }
    void Passes(TestKit::Ctx@ ctx) { ctx.AssertTrue(true); }
    // [TestKit]
    void ExceptionIsolation(TestKit::Ctx@ ctx) {
        TestKit::TestEntry@[] entries;
        entries.InsertLast(TestKit::TestEntry("throws", Throws));
        entries.InsertLast(TestKit::TestEntry("after", Passes));
        auto sink = RecordingSink();
        TestKit::RunSuite(entries, sink);
        ctx.AssertSame(sink.failed, uint(1), "throw becomes one failure");
        ctx.AssertSame(sink.passed, uint(1), "later test still executes");
        ctx.AssertTrue(sink.message.Contains("fixture exception"), "exception text preserved");
        ctx.AssertSame(TestKit::OneLine("a\nb\r"), "a\\nb\\r", "markers stay on one line");
    }

    void ExpectAssertionFailure(TestKit::Ctx@ ctx, TestKit::TestFn@ fn) {
        bool caught = false;
        try { fn(TestKit::Ctx()); }
        catch { caught = true; }
        ctx.AssertTrue(caught, "failing assertion must throw");
    }
    void BadTrue(TestKit::Ctx@ ctx) { ctx.AssertTrue(false); }
    void BadFalse(TestKit::Ctx@ ctx) { ctx.AssertFalse(true); }
    void BadNull(TestKit::Ctx@ ctx) { auto x = SampleObject(); ctx.AssertNull(x); }
    void BadNotNull(TestKit::Ctx@ ctx) { SampleObject@ x; ctx.AssertNotNull(x); }
    void BadSame_int8(TestKit::Ctx@ ctx) { ctx.AssertSame(int8(1), int8(2)); }
    void BadNotSame_int8(TestKit::Ctx@ ctx) { ctx.AssertNotSame(int8(1), int8(1)); }
    void BadSame_int16(TestKit::Ctx@ ctx) { ctx.AssertSame(int16(1), int16(2)); }
    void BadNotSame_int16(TestKit::Ctx@ ctx) { ctx.AssertNotSame(int16(1), int16(1)); }
    void BadSame_int(TestKit::Ctx@ ctx) { ctx.AssertSame(int(1), int(2)); }
    void BadNotSame_int(TestKit::Ctx@ ctx) { ctx.AssertNotSame(int(1), int(1)); }
    void BadSame_int64(TestKit::Ctx@ ctx) { ctx.AssertSame(int64(1), int64(2)); }
    void BadNotSame_int64(TestKit::Ctx@ ctx) { ctx.AssertNotSame(int64(1), int64(1)); }
    void BadSame_uint8(TestKit::Ctx@ ctx) { ctx.AssertSame(uint8(1), uint8(2)); }
    void BadNotSame_uint8(TestKit::Ctx@ ctx) { ctx.AssertNotSame(uint8(1), uint8(1)); }
    void BadSame_uint16(TestKit::Ctx@ ctx) { ctx.AssertSame(uint16(1), uint16(2)); }
    void BadNotSame_uint16(TestKit::Ctx@ ctx) { ctx.AssertNotSame(uint16(1), uint16(1)); }
    void BadSame_uint(TestKit::Ctx@ ctx) { ctx.AssertSame(uint(1), uint(2)); }
    void BadNotSame_uint(TestKit::Ctx@ ctx) { ctx.AssertNotSame(uint(1), uint(1)); }
    void BadSame_uint64(TestKit::Ctx@ ctx) { ctx.AssertSame(uint64(1), uint64(2)); }
    void BadNotSame_uint64(TestKit::Ctx@ ctx) { ctx.AssertNotSame(uint64(1), uint64(1)); }
    void BadSame_float(TestKit::Ctx@ ctx) { ctx.AssertSame(float(1), float(2)); }
    void BadNotSame_float(TestKit::Ctx@ ctx) { ctx.AssertNotSame(float(1), float(1)); }
    void BadSame_double(TestKit::Ctx@ ctx) { ctx.AssertSame(double(1), double(2)); }
    void BadNotSame_double(TestKit::Ctx@ ctx) { ctx.AssertNotSame(double(1), double(1)); }
    void BadSame_string(TestKit::Ctx@ ctx) { ctx.AssertSame("a", "b"); }
    void BadNotSame_string(TestKit::Ctx@ ctx) { ctx.AssertNotSame("a", "a"); }
    void BadApprox_float(TestKit::Ctx@ ctx) { ctx.AssertSameApprox(float(1), float(2)); }
    void BadNotApprox_float(TestKit::Ctx@ ctx) { ctx.AssertNotSameApprox(float(1), float(1)); }
    void BadApprox_double(TestKit::Ctx@ ctx) { ctx.AssertSameApprox(double(1), double(2)); }
    void BadNotApprox_double(TestKit::Ctx@ ctx) { ctx.AssertNotSameApprox(double(1), double(1)); }
    // [TestKit]
    void AssertionFailurePaths(TestKit::Ctx@ ctx) {
        ExpectAssertionFailure(ctx, BadTrue);
        ExpectAssertionFailure(ctx, BadFalse);
        ExpectAssertionFailure(ctx, BadNull);
        ExpectAssertionFailure(ctx, BadNotNull);
        ExpectAssertionFailure(ctx, BadSame_int8);
        ExpectAssertionFailure(ctx, BadNotSame_int8);
        ExpectAssertionFailure(ctx, BadSame_int16);
        ExpectAssertionFailure(ctx, BadNotSame_int16);
        ExpectAssertionFailure(ctx, BadSame_int);
        ExpectAssertionFailure(ctx, BadNotSame_int);
        ExpectAssertionFailure(ctx, BadSame_int64);
        ExpectAssertionFailure(ctx, BadNotSame_int64);
        ExpectAssertionFailure(ctx, BadSame_uint8);
        ExpectAssertionFailure(ctx, BadNotSame_uint8);
        ExpectAssertionFailure(ctx, BadSame_uint16);
        ExpectAssertionFailure(ctx, BadNotSame_uint16);
        ExpectAssertionFailure(ctx, BadSame_uint);
        ExpectAssertionFailure(ctx, BadNotSame_uint);
        ExpectAssertionFailure(ctx, BadSame_uint64);
        ExpectAssertionFailure(ctx, BadNotSame_uint64);
        ExpectAssertionFailure(ctx, BadSame_float);
        ExpectAssertionFailure(ctx, BadNotSame_float);
        ExpectAssertionFailure(ctx, BadSame_double);
        ExpectAssertionFailure(ctx, BadNotSame_double);
        ExpectAssertionFailure(ctx, BadSame_string);
        ExpectAssertionFailure(ctx, BadNotSame_string);
        ExpectAssertionFailure(ctx, BadApprox_float);
        ExpectAssertionFailure(ctx, BadNotApprox_float);
        ExpectAssertionFailure(ctx, BadApprox_double);
        ExpectAssertionFailure(ctx, BadNotApprox_double);
    }
}
#endif
