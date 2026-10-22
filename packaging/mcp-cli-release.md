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
* Linux x64 output: `mcp-cli/target/x86_64-unknown-linux-musl/release/tm-control-mcp`
* Windows x64 output: `mcp-cli/target/x86_64-pc-windows-msvc/release/tm-control-mcp.exe`

If the Rust lane chooses another binary target or output layout, it must update
the package metadata, staging script, and launcher together before release.

## Build and stage

The remote helper is an optional build-box path. It creates an isolated
checkout under the build machine's `~/.cache/tm-control-mcp/builds/`, uses
`~/tmp/tcm-mcp-cli` for temporary files, caps Cargo at two jobs, and runs all
Rust commands remotely. It never falls back to local Cargo:

```bash
./tools/mcp-cli-remote.sh all
```

Use `MCP_CLI_REMOTE_DIR` only for another isolated directory below the printed
remote build root. `MCP_CLI_TARGET` selects a target-specific
`mcp-cli/target/<triple>` output. The helper's `package` action stages an
already-built binary and runs `npm pack`; it does not run `cargo package`.

The GitHub Actions workflow `.github/workflows/mcp-cli.yml` is the canonical
build and test path. Its matrix builds Linux x64 musl and Windows x64 MSVC on
hosted runners, runs fmt/check/test/build with two Cargo jobs, stages and packs
both platform packages, uploads raw binaries and npm tarballs, then downloads
and verifies the combined artifact set. Windows uses the target-scoped
`.cargo/config.toml` static CRT setting and rejects dynamic CRT DLLs. The
workflow runs on pull requests and is manually dispatchable for release
preparation; it never publishes npm packages.

For a manual Windows build box, use the same target and output layout, then
stage its executable without running Cargo from this checkout:

```bash
python3 packaging/mcp-cli-package.py \
  --platform win32-x64 \
  --binary mcp-cli/target/x86_64-pc-windows-msvc/release/tm-control-mcp.exe \
  --version 0.1.0 \
  --output dist/mcp-cli
```

The version is the version being prepared; the example only documents the
initial package metadata. The CI smoke installs packed packages offline,
compares installed executable bytes with the raw build artifact, and compares
`tm-control-mcp --version` output.

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

The release preparation artifact is intentionally not published. A later
release action or human release step may publish the three verified tarballs
after the normal version and release approval process.
