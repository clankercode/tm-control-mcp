#!/usr/bin/env python3
"""Offline npm install of the packed CLI, with actual executable verification.

Run this on the build machine matching --platform. No Cargo or registry
downloads are used. Both the binary bytes and --version must survive packing,
installation and the npm launcher.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def run(arguments: list[str], cwd: Path) -> bytes:
    result = subprocess.run(arguments, cwd=cwd, check=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=60, shell=False)
    return result.stdout


def smoke(artifact_root: Path, binary: Path, platform: str) -> None:
    artifact_root, binary = artifact_root.resolve(), binary.resolve()
    expected_host = "win32" if platform == "win32-x64" else "linux"
    if sys.platform != expected_host:
        raise SystemExit(f"{platform} must be smoke-tested on {expected_host}, got {sys.platform}")
    npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
    if npm is None:
        raise SystemExit("npm is required for the offline packed-install smoke")
    packages = {}
    for path in artifact_root.glob("*.tgz"):
        with tarfile.open(path) as archive:
            metadata = json.load(archive.extractfile("package/package.json"))
            name = metadata["name"]
            if name in packages:
                raise SystemExit(f"duplicate packed package: {name}")
            packages[name] = path
    root_name = "@clankercode/tm-control-mcp"
    platform_name = f"{root_name}-{platform}"
    if root_name not in packages or platform_name not in packages:
        raise SystemExit("root and selected platform tarballs are required for the install smoke")
    expected = run([str(binary), "--version"], artifact_root)
    if not expected.strip():
        raise SystemExit("built binary --version returned empty output")
    with tempfile.TemporaryDirectory(prefix="tcm-npm-install-", dir=artifact_root.parent) as temporary:
        project = Path(temporary)
        (project / "package.json").write_text('{"name":"tcm-install-smoke","private":true}', encoding="utf-8")
        run([npm, "install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
             "--include=optional", str(packages[root_name]), str(packages[platform_name])], project)
        filename = "tm-control-mcp.exe" if platform == "win32-x64" else "tm-control-mcp"
        installed = project / "node_modules" / platform_name / "bin" / filename
        if installed.read_bytes() != binary.read_bytes():
            raise SystemExit("installed executable bytes differ from the built binary")
        actual = run([npm, "exec", "--offline", "--", "tm-control-mcp", "--version"], project)
        if actual != expected:
            raise SystemExit(f"installed CLI --version differs: {actual!r} != {expected!r}")
    print(f"{platform}: offline packed npm install, executable bytes and --version verified")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--platform", choices=["linux-x64", "win32-x64"], required=True)
    args = parser.parse_args()
    smoke(args.artifact_root, args.binary, args.platform)


if __name__ == "__main__":
    main()
