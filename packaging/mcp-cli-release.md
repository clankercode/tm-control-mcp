# MCP CLI distribution

The npm distribution has one launcher package and one optional package per
supported platform:

| Package | npm platform | executable inside the package |
| --- | --- | --- |
| `@clankercode/tm-control-mcp` | any supported host | `bin/tm-control-mcp.js` |
| `@clankercode/tm-control-mcp-linux-x64` | `linux` / `x64` | `bin/tm-control-mcp` |
| `@clankercode/tm-control-mcp-win32-x64` | `win32` / `x64` | `bin/tm-control-mcp.exe` |

The root package has no install lifecycle scripts. npm's platform filtering
selects the matching optional dependency. The launcher calls the executable
with `spawn(..., {stdio: "inherit", shell: false})`, passes `process.argv`
after the launcher name, forwards termination signals, and exits with the
child's status. It never downloads or builds a binary during installation.

The Rust lane must provide this stable boundary:

* Cargo manifest: `mcp-cli/Cargo.toml`
* release binary target: `tm-control-mcp`
* Linux x64 output: `target/release/tm-control-mcp`
* Windows x64 output: `target/release/tm-control-mcp.exe`

If the Rust lane chooses another binary target or output layout, it must update
the package metadata, staging script, and launcher together before release.

## Build and stage

Linux x64 is built on x-p35 through the orchestration helper. The helper makes
an isolated remote checkout, checks that Cargo, Python, and npm are available
there, and runs fmt, check, test, build, and package through SSH. It never
invokes local Cargo:

```bash
./tools/mcp-cli-remote.sh all
```

Use `MCP_CLI_REMOTE_DIR=/tmp/my-build` when a stable remote path is useful for
inspection. The generated packages are under the remote `dist/packages`
directory. Use `sync`, `check`, `test`, `build`, or `package` separately when
debugging a build-box failure.

Windows x64 remains a manual build-box step until a trusted Windows runner is
available. On that box, run the Rust lane's normal locked fmt/check/test/build
commands, then stage its executable without running Cargo from this checkout:

```bash
python3 packaging/mcp-cli-package.py \
  --platform win32-x64 \
  --binary target/release/tm-control-mcp.exe \
  --version 0.1.0 \
  --output dist/mcp-cli
```

The version is the version being published; the example only documents the
initial package metadata. Staging both platforms into the same output root
keeps the root launcher metadata and optional dependency versions identical.

## Verify and publish

Run the source checks on any machine:

```bash
python3 packaging/verify-mcp-cli-artifacts.py --source-only
node --test mcp-cli/npm/test/*.test.mjs
```

After both platform packages have been staged, verify the actual executables:

```bash
python3 packaging/verify-mcp-cli-artifacts.py \
  --artifact-root dist/mcp-cli \
  --version 0.1.0
```

The verifier accepts staged package directories or the `.tgz` files produced by
`npm pack`. It checks that both platform packages contain the expected binary,
that Linux has an executable bit, and that no install or download hook has
appeared.

The GitHub Actions workflow `.github/workflows/mcp-cli.yml` is manual by
design. Its hosted runner verifies source metadata and launcher behavior, then
prints the build-box procedure. It does not label a hosted runner as x-p35 and
does not run Cargo. Publish the verified packages from the build box:

```bash
npm publish --access public dist/mcp-cli/tm-control-mcp
npm publish --access public dist/mcp-cli/tm-control-mcp-linux-x64
npm publish --access public dist/mcp-cli/tm-control-mcp-win32-x64
```
