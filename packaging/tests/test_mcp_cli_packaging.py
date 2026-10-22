"""Distribution regression checks. All binaries are fixtures; no local Cargo."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load_module(filename):
    path = ROOT / "packaging" / filename
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage_tool = load_module("mcp-cli-package.py")
verify_tool = load_module("verify-mcp-cli-artifacts.py")
smoke_tool = load_module("smoke-mcp-cli-package.py")


def edit_json(path, edit):
    metadata = json.loads(path.read_text(encoding="utf-8"))
    edit(metadata)
    path.write_text(json.dumps(metadata), encoding="utf-8")


class PackagingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".test-deps").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="package-test-", dir=ROOT / ".test-deps")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = ROOT / "mcp-cli/npm"
        self.output = self.base / "staged"
        self.binary = self.base / "tm-control-mcp"
        # A fixture process exercises the launcher and npm shims without Rust.
        self.binary.write_bytes(b'#!/usr/bin/env node\nprocess.stdout.write("fixture 0.1.0\\n");\n')
        self.binary.chmod(0o755)

    def stage(self, platform="linux-x64", version="0.1.0"):
        stage_tool.stage(self.source, self.output, platform, self.binary, version)

    def verify(self, platform=None, version="0.1.0", binary_root=None):
        verify_tool.verify_artifacts(self.output, version, platform, binary_root)

    def test_source_metadata(self):
        verify_tool.verify_source(self.source)
        launcher = self.source / "tm-control-mcp/bin/tm-control-mcp.js"
        self.assertTrue(launcher.read_bytes().startswith(b"#!/usr/bin/env node\n"))
        for platform in stage_tool.PLATFORMS.values():
            metadata = json.loads((self.source / platform["directory"] / "package.json").read_text())
            self.assertNotIn("bin", metadata, "platform bins must not override the root npm shim")

    def test_single_platform_verification_and_complete_release_gate(self):
        self.stage()
        self.verify("linux-x64")
        with self.assertRaisesRegex(SystemExit, "missing.*win32-x64"):
            self.verify()
        self.stage("win32-x64")
        self.verify()

    def test_stage_copies_exact_binary_and_replaces_stale_output(self):
        original_metadata = (self.source / "tm-control-mcp/package.json").read_bytes()
        self.stage(version="1.2.3-rc.1")
        stale = self.output / "tm-control-mcp-linux-x64" / "stale.txt"
        stale.touch()
        self.stage(version="1.2.3-rc.1")
        self.assertFalse(stale.exists())
        self.assertEqual((self.output / "tm-control-mcp-linux-x64/bin/tm-control-mcp").read_bytes(), self.binary.read_bytes())
        self.assertEqual((self.source / "tm-control-mcp/package.json").read_bytes(), original_metadata)
        metadata = json.loads((self.output / "tm-control-mcp/package.json").read_text())
        self.assertEqual(set(metadata["optionalDependencies"].values()), {"1.2.3-rc.1"})

    def test_stage_rejects_invalid_versions_missing_binary_and_overlap(self):
        for version in ("01.2.3", "1.2", "1.2.3-01", "1.2.3-rc..1"):
            with self.subTest(version=version), self.assertRaisesRegex(SystemExit, "invalid npm"):
                self.stage(version=version)
        with self.assertRaisesRegex(SystemExit, "built binary does not exist"):
            stage_tool.stage(self.source, self.output, "linux-x64", self.base / "absent", "0.1.0")
        with self.assertRaisesRegex(SystemExit, "output must be separate"):
            stage_tool.stage(self.source, self.source, "linux-x64", self.binary, "0.1.0")

    def test_stage_rejects_mixed_release_versions(self):
        self.stage()
        with self.assertRaisesRegex(SystemExit, "another package version"):
            self.stage("win32-x64", "0.2.0")

    def test_verifier_rejects_missing_or_empty_binary(self):
        self.stage()
        binary = self.output / "tm-control-mcp-linux-x64/bin/tm-control-mcp"
        binary.unlink()
        with self.assertRaisesRegex(SystemExit, "missing bin/tm-control-mcp"):
            self.verify("linux-x64")
        binary.write_bytes(b"")
        with self.assertRaisesRegex(SystemExit, "empty binary"):
            self.verify("linux-x64")

    def test_verifier_rejects_install_hooks_platform_drift_and_version_drift(self):
        for change, error in (
            (lambda data: data.update(scripts={"postinstall": "download"}), "lifecycle scripts"),
            (lambda data: data.update(cpu=["arm64"]), "platform metadata"),
            (lambda data: data.update(version="0.9.0"), "version"),
            (lambda data: data.update(exports={}), "does not export"),
        ):
            with self.subTest(error=error):
                self.stage()
                edit_json(self.output / "tm-control-mcp-linux-x64/package.json", change)
                with self.assertRaisesRegex(SystemExit, error):
                    self.verify("linux-x64")
                shutil.rmtree(self.output)

    def test_verifier_rejects_root_metadata_and_shebang_drift(self):
        self.stage()
        edit_json(self.output / "tm-control-mcp/package.json", lambda data: data.update(optionalDependencies={}))
        with self.assertRaisesRegex(SystemExit, "optionalDependencies"):
            self.verify("linux-x64")
        self.stage()
        (self.output / "tm-control-mcp/bin/tm-control-mcp.js").write_text("invalid")
        with self.assertRaisesRegex(SystemExit, "shebang"):
            self.verify("linux-x64")

    def test_downloaded_binary_must_equal_packed_binary(self):
        self.stage()
        binaries = self.base / "download"
        destination = binaries / "mcp-cli-binary-linux-x64/tm-control-mcp"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(self.binary.read_bytes())
        self.verify("linux-x64", binary_root=binaries)
        destination.write_bytes(b"different build")
        with self.assertRaisesRegex(SystemExit, "does not match downloaded build"):
            self.verify("linux-x64", binary_root=binaries)

    @unittest.skipUnless(shutil.which("npm"), "npm is required for fixture pack verification")
    def test_npm_tarballs_and_offline_installed_launcher_without_cargo(self):
        self.stage()
        packed = self.base / "packages"
        stage_tool.pack(self.output, packed, "linux-x64")
        verify_tool.verify_artifacts(packed, "0.1.0", "linux-x64")
        if sys.platform == "linux":
            smoke_tool.smoke(packed, self.binary, "linux-x64")


@unittest.skipIf(os.name == "nt", "SSH orchestration helper is a POSIX shell tool")
class RemoteHelperTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".test-deps").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="remote-helper-test-", dir=ROOT / ".test-deps")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.bin = self.base / "tools"
        self.bin.mkdir()
        self.log = self.base / "calls.jsonl"
        stub = "#!/usr/bin/env python3\n" + '''import json, os, pathlib, sys
with open(os.environ["TCM_TEST_LOG"], "a") as stream:
    stream.write(json.dumps([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
name = pathlib.Path(sys.argv[0]).name
if name == "cargo":
    raise SystemExit("local Cargo must never be called")
if os.environ.get("TCM_TEST_FAIL_SSH") and name == "ssh":
    raise SystemExit(122)
if name == "ssh" and sys.argv[-1] == 'printf "%s" "$HOME"':
    print("/home/build user", end="")
'''
        for name in ("ssh", "rsync", "cargo"):
            executable = self.bin / name
            executable.write_text(stub, encoding="utf-8")
            executable.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("MCP_CLI_")}
        self.env.update(PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", TCM_TEST_LOG=str(self.log), MCP_CLI_VERSION="0.1.0")

    def run_helper(self, action, **environment):
        return subprocess.run(["bash", str(ROOT / "tools/mcp-cli-remote.sh"), action],
                              cwd=self.base, env={**self.env, **environment},
                              text=True, capture_output=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_home_checkout_tmpdir_two_jobs_and_remote_cargo_only(self):
        result = self.run_helper("all")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertFalse(any(call[0] == "cargo" for call in calls))
        cargo_commands = [call[-1] for call in calls if call[0] == "ssh" and "&& cargo " in call[-1]]
        self.assertEqual(len(cargo_commands), 4)
        for command in cargo_commands:
            self.assertIn("/home/build user/.cache/tm-control-mcp/builds/checkout-", command)
            self.assertIn("TMPDIR='/home/build user/tmp/tcm-mcp-cli/", command)
            self.assertIn("CARGO_BUILD_JOBS=2", command)
            self.assertIn("/mcp-cli/target'", command)
            self.assertIn("cd mcp-cli && cargo", command)
            if "cargo fmt" not in command:
                self.assertIn("--jobs 2", command)
        package_command = next(call[-1] for call in calls if "python3 packaging/mcp-cli-package.py" in call[-1])
        self.assertIn("mcp-cli/target/release/tm-control-mcp", package_command)
        self.assertNotIn("cargo package", "\n".join(str(call) for call in calls))

    def test_package_only_never_invokes_cargo_and_uses_selected_target_path(self):
        result = self.run_helper("package", MCP_CLI_TARGET="x86_64-unknown-linux-musl")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = "\n".join(call[-1] for call in self.calls())
        self.assertNotIn("&& cargo", commands)
        self.assertIn("mcp-cli/target/x86_64-unknown-linux-musl/release/tm-control-mcp", commands)
        self.assertIn("--platform 'linux-x64'", commands)

    def test_unavailable_build_box_fails_without_local_fallback(self):
        result = self.run_helper("test", TCM_TEST_FAIL_SSH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unavailable; no local Cargo fallback", result.stderr)
        self.assertFalse(any(call[0] == "cargo" for call in self.calls()))

    def test_rejects_shared_or_tmp_remote_checkout(self):
        for path in ("/tmp/build", "/home/build user", "/home/build user/.cache/tm-control-mcp/builds/../oops"):
            with self.subTest(path=path):
                result = self.run_helper("sync", MCP_CLI_REMOTE_DIR=path)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
