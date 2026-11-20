# Reusable TestKit sample

Openplanet discovers `[Test]` functions, but its native test runner needs a UI
trigger. Plugin load alone does not execute them. The sample in
[`examples/testkit/`](../examples/testkit/) makes the same test bodies available
at DEV startup, through one native adapter, and through an optional tool pack.
It is a copyable example, not a dependency of the bridge or a production service.
Python helpers use only the standard library.

## Adopt it

1. Copy `examples/testkit/TestKit.as` into your plugin's `src/TestKit.as`.
2. Keep ordinary `[Test] void Name(Tests::Context@ ctx)` test bodies, with
   actual values before expected values. Enable `defines = ["DEV"]` in your
   development manifest and enclose test files in `#if DEV`.
3. Run the generator explicitly to convert the parameter types and metadata:

   ```bash
   python3 examples/testkit/gen_registry.py --plugin-dir /path/to/plugin --rewrite
   python3 examples/testkit/gen_registry.py --plugin-dir /path/to/plugin --check
   ```

   A converted function has a `// [TestKit]` marker followed by
   `void Name(TestKit::Ctx@ ctx)`. Its `ctx.Assert*` body stays unchanged.
   The generator writes `src/_TestRegistry.as`, with deterministic names and
   registration plus one native `[Test]` aggregate. Keep that file in source
   control; rerun the generator whenever tests change. `--check` never writes.
4. Call `TestKit::RunSelfChecks("your-plugin-id")` from `Main()` under `#if DEV`.
   Use the installed folder ID as the suite name, or pass `--suite` to the runner.
5. Stage your plugin using its own build process, check it with `openplanet-lsp`,
   then invoke the runner. The runner reloads an already staged folder; it does
   **not** copy or build source. Always prove staged bytes match the source.

`Ctx` has all 30 overloads in Openplanet 1.29.14's `Tests::Context`: True/False,
Null/NotNull (`ref`), Same/NotSame for int8/int16/int/int64, uint8/uint16/uint/uint64,
float, double and string, and SameApprox/NotSameApprox for float and double.
Messages are optional and default to an empty string. See the
[official Context API](https://openplanet.dev/docs/api/Tests/Context).
The exact signatures also live in `OpenplanetCore.json` in an Openplanet profile.
Approximate comparisons use an inclusive absolute tolerance of 1e-5 for float and
1e-9 for double, with double differences compared in double precision. The native
API does not document its tolerance, so numeric policy parity is not promised.
Equal infinities compare equal; NaN never compares equal.

## Marker and result contract

Each invocation logs the following, with Openplanet's normal logger prefix:

```text
SELFCHECK BEGIN: your-plugin-id, 2 registered
SELFCHECK PASS: your-plugin-id / Tests::First
SELFCHECK FAIL: your-plugin-id / Tests::Second / assertion message (detail)
SELFCHECK SUITE: your-plugin-id, 1 passed, 1 failed
```

Counts are **test functions**, not assertions. Each registered test produces one
PASS or FAIL. The first failed assertion throws and aborts that test; the driver
captures the exception text and continues with the next test. An explicit throw
is captured the same way, and a function with no assertions can pass. Exception
newlines become literal `\n`/`\r`, keeping every marker on one physical line.
Names are qualified with their namespace; generated callbacks use absolute
`::` references so a same-named function inside `TestKit` cannot shadow a global test. Suite names for the runner use letters,
numbers, underscore, dot, colon or hyphen; avoid commas and ` / `.

`TestKit::Sink` has `Check(bool ok, const string &in msg)`. `LogSink` emits these
markers and stores `passed`, `failed`, and `failures`. `CtxSink` borrows a native
`Tests::Context@` for one synchronous aggregate invocation. Never retain that
context after the native test returns. `Reg(name, fn)` rejects null callbacks and
duplicate names; `RunAll(suite)` returns a `LogSink@` after reporting, while
`RunAll(Sink@)` lets the native adapter or a custom sink run the same registry.
`RunSelfChecks(suite)` returns JSON:

```json
{"suite":"your-plugin-id","registered":2,"passed":1,"failed":1,
 "failures":["Tests::Second / assertion message (detail)"]}
```

## Run the example

The example is windowless: its inspectable demo is its log output and optional
`testkit.RunSelfChecks` tool. There is no game-state mutation or UI setup. Its
`src/TestKit.as` is a relative symlink to the canonical sample; dereference that
symlink when copying to Windows (for example `cp -RL` into your staging tree).
The six tests exercise every assertion overload, double tolerance boundaries,
failure paths, null handles, large integers, and exception isolation. The
intentionally failing inner fixtures use a recording sink, so the outer sample
suite passes.

```bash
python3 examples/testkit/gen_registry.py --plugin-dir examples/testkit/example-plugin --check
python3 -m unittest discover -s examples/testkit/tests -v
openplanet-lsp check --typedb-dir /path/to/OpenplanetNext \
  --plugins-dir /path/containing/tm-control-mcp examples/testkit/example-plugin

# After copying the example into OpenplanetNext/Plugins/testkit-sample:
python3 examples/testkit/run_plugin_tests.py \
  --plugin-dir examples/testkit/example-plugin --plugin-id testkit-sample \
  --log /path/to/OpenplanetNext/Openplanet.log --host 127.0.0.1 --port 30000
```

The runner checks registry drift before any live action, records the byte offset,
reloads via `tm-remote-build` when available (bounded raw RemoteBuild fallback
otherwise), and accepts only a fresh BEGIN, exactly one verdict per registered
name, and matching summary counts. Old summaries cannot pass a new run.
Replacement/truncation during a run is an infrastructure error; rerun against the
new log. Python stdout contains a per-test table and summary. Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Every registered test passed |
| 1 | Suite completed with test failures |
| 2 | Infrastructure, stale registry, malformed/incomplete results, or timeout |

For a remote game, forward RemoteBuild and the bridge over SSH, and supply a log
command whose stdout contains only raw Openplanet log bytes:

```bash
python3 examples/testkit/run_plugin_tests.py \
  --plugin-dir /path/to/plugin --plugin-id your-plugin-id \
  --host 127.0.0.1 --port 31000 --timeout 45 \
  --log-cmd 'ssh remote-host cat /path/to/Openplanet.log'
```

`--log-cmd` runs a shell command you supply. It must produce a consistent byte
stream on every call, with new data appended. For a very large shared log, a
remote helper may expose a fixed-offset suffix captured before running the
runner, provided it rejects truncation below that baseline. Keep SSH diagnostics
on stderr. The CLI only reloads the plugin ID; source transfer and host leases
remain the caller's responsibility.

## Rerun over a tool pack

The example declares `optional_dependencies = ["tm-control-mcp"]`. With that
bridge loaded, `#if DEV && DEPENDENCY_TM_CONTROL_MCP` registers a
`TmMcp::ToolPackBuilder("testkit")` dispatch exposing `RunSelfChecks`. Both
`OnDisabled` and `OnDestroyed` unregister it. With the dependency absent, the
load-time tests and native adapter remain available. See [tool packs](tool-packs.md)
for the API. An unpublished fixture intentionally has no release-update URL;
bridge versions with update discovery may warn about missing metadata.

```bash
python3 examples/testkit/run_plugin_tests.py \
  --plugin-dir examples/testkit/example-plugin --plugin-id testkit-sample \
  --via-tool-pack testkit.RunSelfChecks \
  --call-script tools/call.py --socket-host 127.0.0.1 --socket-port 30006
```

The tool accepts `{}` and returns `{success:true, output:<report>}` even when
assertions fail: a failed assertion is a completed test run. The runner validates
suite, registry count, nonnegative integer counts and each named failure, then
uses exit 1 for test failures. This path needs no reload or log reader. For a
custom tool, return the same JSON schema and the suite selected by `--suite`.

**Executing-plugin ownership differs by route.** Load-time `Main()` runs as the
adopting plugin. This direct, synchronous tool-pack dispatch runs test bodies
under the bridge's `Meta::ExecutingPlugin()` identity (`tm-control-mcp`). Calls
such as `IO::FromStorageFolder` therefore resolve the bridge's storage, and
per-plugin hooks, allocations and coroutines can belong to the bridge. This
sample's rerun route supports only context-independent tests using pure/local
fixtures. For tests that need plugin ownership, use an adopter-owned execution
mechanism and verify its identity and resource cleanup before exposing reruns.
An inline `startnew` is not a proven ownership switch. Native UI runner ownership
has not been verified here; sharing test bodies does not establish that identity.

## Pitfalls carried forward from Dips++ and MapTogether

- Passing a null native context works only for bodies that never dereference it.
  Convert the parameter to `TestKit::Ctx@` before using this driver.
- Leaving individual native `[Test]` functions beside an aggregate executes
  those tests twice in the UI. Conversion removes their metadata and generates
  just one native adapter. Never edit that generated adapter by hand.
- A hand-maintained registry can silently omit new tests. The runner checks the
  generated file against source on every run, including tool-pack reruns.
- Assertions and tests have different counts. Compare registered test names and
  terminal results, rather than assuming every assertion produces a PASS line.
- Tests must own and restore their mutations. Dips++ tests historically cleared
  live collectibles/hats, and recomputing unlocks played audio during reload.
  Use pure seams/local fixtures here; a generic harness cannot restore another
  plugin's persistent stores, retained handles, animations or map state.
- Imported calls can change the executing-plugin identity: direct bridge reruns
  do not have the load-time plugin's ownership. Dips++ observed hooks/allocations
  assigned to the caller, then freed or unhooked with the wrong owner. Keep this
  synchronous rerun pattern context-independent; verify adopter-owned execution
  and cleanup separately for per-plugin APIs, including storage and coroutines.
  Neither inline `startnew` nor the native UI adapter proves owner-context parity.
- Keep tests synchronous, independent and bounded. Never keep a native context
  across yields. A test that wedges or exhausts Openplanet's execution budget
  cannot be rescued by exception capture; the host runner times out with exit 2.
- A second reload while waiting can duplicate a valid suite. This runner issues
  one reload and requires fresh markers; fix the lifecycle cause before retrying.
- Shell pipelines can report SIGPIPE as a failed test run when a consumer stops
  after the summary. These helpers use Python byte snapshots and subprocess
  results instead of grep/pipe-status heuristics.
- The generator scans syntax and explicit markers, not an AngelScript compiler.
  Put tests in DEV-only files, keep them namespace/global functions, and use
  identical compilation guards for tests and their generated registry. Advanced
  conditional alternatives or overloaded test names need separate registries or
  a small custom registration layer. Comments and string literals are ignored.

Release manifests should omit DEV. `TestKit.as`, converted tests, generated
registry, and the tool-pack callbacks are all guarded out of release builds.
