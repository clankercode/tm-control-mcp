import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = fileURLToPath(new URL(".", import.meta.url));
const require = createRequire(import.meta.url);
const packageRoot = new URL("../tm-control-mcp/", import.meta.url);
const packageJson = JSON.parse(
  await readFile(new URL("package.json", packageRoot), "utf8")
);
const launcherText = await readFile(
  new URL("bin/tm-control-mcp.js", packageRoot),
  "utf8"
);
const launcher = require("../tm-control-mcp/bin/tm-control-mcp.js");

test("root package declares both platform packages as optional dependencies", () => {
  assert.equal(packageJson.bin["tm-control-mcp"], "bin/tm-control-mcp.js");
  assert.deepEqual(packageJson.optionalDependencies, {
    "@clankercode/tm-control-mcp-linux-x64": packageJson.version,
    "@clankercode/tm-control-mcp-win32-x64": packageJson.version
  });
  assert.equal(packageJson.scripts, undefined);
});

test("launcher maps only the published x64 platforms", () => {
  assert.deepEqual(launcher.PLATFORM_PACKAGES["linux-x64"], {
    packageName: "@clankercode/tm-control-mcp-linux-x64",
    binaryPath: "bin/tm-control-mcp"
  });
  assert.deepEqual(launcher.PLATFORM_PACKAGES["win32-x64"], {
    packageName: "@clankercode/tm-control-mcp-win32-x64",
    binaryPath: "bin/tm-control-mcp.exe"
  });
  assert.throws(
    () => launcher.resolvePlatformBinary({ platform: "darwin", arch: "arm64" }),
    /Unsupported platform darwin-arm64/
  );
});

test("launcher reports a missing optional dependency clearly", () => {
  assert.throws(
    () =>
      launcher.resolvePlatformBinary({
        platform: "linux",
        arch: "x64",
        resolveImpl: () => {
          const error = new Error("not found");
          error.code = "MODULE_NOT_FOUND";
          throw error;
        }
      }),
    /optional platform package @clankercode\/tm-control-mcp-linux-x64 is not installed/
  );
});

test("launcher forwards argv, stdio, signals, and exit status", () => {
  class FakeChild extends EventEmitter {
    killed = false;
    exitCode = null;
    signals = [];

    kill(signal) {
      this.signals.push(signal);
      this.killed = true;
    }
  }

  const child = new FakeChild();
  const handlers = new Map();
  const processRef = {
    exitCode: undefined,
    on(signal, handler) {
      handlers.set(signal, handler);
    },
    removeListener(signal, handler) {
      assert.equal(handlers.get(signal), handler);
      handlers.delete(signal);
    }
  };
  const spawnCalls = [];
  const returned = launcher.launch({
    platform: "linux",
    arch: "x64",
    argv: ["--stdio", "--port", "42"],
    resolveImpl: (specifier) => `/fake/${specifier}`,
    spawnImpl: (...args) => {
      spawnCalls.push(args);
      return child;
    },
    processRef,
    consoleRef: { error() {} }
  });

  assert.equal(returned, child);
  assert.deepEqual(spawnCalls, [
    [
      "/fake/@clankercode/tm-control-mcp-linux-x64/bin/tm-control-mcp",
      ["--stdio", "--port", "42"],
      { stdio: "inherit", shell: false }
    ]
  ]);
  handlers.get("SIGTERM")();
  assert.deepEqual(child.signals, ["SIGTERM"]);
  child.emit("exit", 17, null);
  assert.equal(processRef.exitCode, 17);
  assert.equal(handlers.size, 0);
});

test("launcher source keeps the no-shell and argument-forwarding contract visible", () => {
  assert.match(launcherText, /spawnImpl\(/);
  assert.match(launcherText, /argv = process\.argv\.slice\(2\)/);
  assert.match(launcherText, /stdio: "inherit"/);
  assert.match(launcherText, /shell: false/);
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"]) {
    assert.match(launcherText, new RegExp(signal));
  }
  assert.ok(here.endsWith("/test/"));
});
