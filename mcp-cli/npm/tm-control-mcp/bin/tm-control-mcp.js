#!/usr/bin/env node
"use strict";

const { spawn } = require("node:child_process");

const PLATFORM_PACKAGES = Object.freeze({
  "linux-x64": Object.freeze({
    packageName: "@clankercode/tm-control-mcp-linux-x64",
    binaryPath: "bin/tm-control-mcp"
  }),
  "win32-x64": Object.freeze({
    packageName: "@clankercode/tm-control-mcp-win32-x64",
    binaryPath: "bin/tm-control-mcp.exe"
  })
});

const FORWARDED_SIGNALS = Object.freeze([
  "SIGINT",
  "SIGTERM",
  "SIGHUP",
  "SIGQUIT"
]);

const SIGNAL_EXIT_CODES = Object.freeze({
  SIGHUP: 129,
  SIGINT: 130,
  SIGQUIT: 131,
  SIGTERM: 143
});

function platformKey(platform = process.platform, arch = process.arch) {
  return `${platform}-${arch}`;
}

function unsupportedPlatformError(platform, arch) {
  const supported = Object.keys(PLATFORM_PACKAGES).join(", ");
  return new Error(
    `[tm-control-mcp] Unsupported platform ${platform}-${arch}. ` +
      `Published platforms: ${supported}.`
  );
}

function missingDependencyError(packageName, cause) {
  const error = new Error(
    `[tm-control-mcp] The optional platform package ${packageName} is not installed. ` +
      `Reinstall with optional dependencies enabled, for example: ` +
      `npm install --include=optional @clankercode/tm-control-mcp.`,
    { cause }
  );
  error.code = "MCP_CLI_PLATFORM_PACKAGE_MISSING";
  return error;
}

function resolvePlatformBinary({
  platform = process.platform,
  arch = process.arch,
  resolveImpl = require.resolve
} = {}) {
  const descriptor = PLATFORM_PACKAGES[platformKey(platform, arch)];
  if (!descriptor) {
    throw unsupportedPlatformError(platform, arch);
  }

  try {
    return {
      ...descriptor,
      platform,
      arch,
      path: resolveImpl(`${descriptor.packageName}/${descriptor.binaryPath}`)
    };
  } catch (error) {
    if (error && error.code === "MODULE_NOT_FOUND") {
      throw missingDependencyError(descriptor.packageName, error);
    }
    throw error;
  }
}

function launch({
  argv = process.argv.slice(2),
  platform = process.platform,
  arch = process.arch,
  resolveImpl = require.resolve,
  spawnImpl = spawn,
  processRef = process,
  consoleRef = console
} = {}) {
  const executable = resolvePlatformBinary({ platform, arch, resolveImpl });
  let child;
  const signalHandlers = new Map();
  let settled = false;

  const cleanup = () => {
    for (const [signal, handler] of signalHandlers) {
      processRef.removeListener(signal, handler);
    }
    signalHandlers.clear();
  };

  const finish = (code, signal) => {
    if (settled) return;
    settled = true;
    cleanup();
    processRef.exitCode = signal ? SIGNAL_EXIT_CODES[signal] || 1 : code ?? 1;
  };

  try {
    child = spawnImpl(executable.path, argv, {
      stdio: "inherit",
      shell: false
    });
  } catch (error) {
    cleanup();
    throw error;
  }

  const forwardSignal = (signal) => {
    if (settled || child.exitCode !== null) return;
    try {
      child.kill(signal);
    } catch (error) {
      if (!error || error.code !== "ESRCH") throw error;
    }
  };

  for (const signal of FORWARDED_SIGNALS) {
    const handler = () => forwardSignal(signal);
    signalHandlers.set(signal, handler);
    processRef.on(signal, handler);
  }

  child.once("error", (error) => {
    if (settled) return;
    consoleRef.error(`[tm-control-mcp] Failed to start ${executable.path}: ${error.message}`);
    finish(1, null);
  });
  child.once("exit", (code, signal) => finish(code, signal));
  return child;
}

if (require.main === module) {
  try {
    launch();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  FORWARDED_SIGNALS,
  PLATFORM_PACKAGES,
  launch,
  platformKey,
  resolvePlatformBinary
};
