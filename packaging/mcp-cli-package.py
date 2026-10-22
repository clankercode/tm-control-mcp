#!/usr/bin/env python3
"""Stage one Rust MCP CLI binary into the npm package layout.

This script only copies an already-built executable. It never invokes Cargo,
downloads dependencies, or runs an install hook.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT_PACKAGE_DIR = "tm-control-mcp"
PLATFORMS = {
    "linux-x64": {
        "directory": "tm-control-mcp-linux-x64",
        "package": "@clankercode/tm-control-mcp-linux-x64",
        "binary": "tm-control-mcp",
    },
    "win32-x64": {
        "directory": "tm-control-mcp-win32-x64",
        "package": "@clankercode/tm-control-mcp-win32-x64",
        "binary": "tm-control-mcp.exe",
    },
}
VERSION_RE = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def valid_version(version: str) -> bool:
    match = VERSION_RE.fullmatch(version)
    return bool(match) and all(
        not (part.isdigit() and len(part) > 1 and part.startswith("0"))
        for part in (match.group(4) or "").split(".")
    )


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read JSON metadata {path}: {error}") from error


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def copy_package(source: Path, destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for filename in ("package.json", "README.md"):
        shutil.copy2(source / filename, destination / filename)
    if source.name == ROOT_PACKAGE_DIR:
        (destination / "bin").mkdir()
        launcher = destination / "bin" / "tm-control-mcp.js"
        shutil.copy2(source / "bin" / "tm-control-mcp.js", launcher)
        launcher.chmod(0o755)


def stage(source_root: Path, output_root: Path, platform: str, binary: Path, version: str) -> None:
    descriptor = PLATFORMS[platform]
    root_source = source_root / ROOT_PACKAGE_DIR
    platform_source = source_root / descriptor["directory"]
    if not root_source.is_dir() or not platform_source.is_dir():
        raise SystemExit(f"npm package source is incomplete under {source_root}")
    if not binary.is_file():
        raise SystemExit(f"built binary does not exist: {binary}")
    if not valid_version(version):
        raise SystemExit(f"invalid npm package version: {version!r}")

    source_root = source_root.resolve()
    output_root = output_root.resolve()
    binary = binary.resolve()
    if (source_root.is_relative_to(output_root) or output_root.is_relative_to(source_root)
            or binary.is_relative_to(output_root)):
        raise SystemExit("output must be separate from the source packages and input binary")
    # Never silently combine binaries from different releases.
    for item in PLATFORMS.values():
        metadata_path = output_root / item["directory"] / "package.json"
        if metadata_path.is_file() and read_json(metadata_path).get("version") != version:
            raise SystemExit("output contains another package version; use a fresh output directory")

    output_root.mkdir(parents=True, exist_ok=True)
    root_destination = output_root / ROOT_PACKAGE_DIR
    platform_destination = output_root / descriptor["directory"]
    copy_package(root_source, root_destination)
    copy_package(platform_source, platform_destination)

    root_metadata = read_json(root_destination / "package.json")
    root_metadata["version"] = version
    optional_dependencies = root_metadata.get("optionalDependencies", {})
    for package_name in optional_dependencies:
        optional_dependencies[package_name] = version
    write_json(root_destination / "package.json", root_metadata)

    platform_metadata = read_json(platform_destination / "package.json")
    platform_metadata["version"] = version
    write_json(platform_destination / "package.json", platform_metadata)

    binary_destination = platform_destination / "bin" / descriptor["binary"]
    binary_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, binary_destination)
    if platform == "linux-x64":
        binary_destination.chmod(binary_destination.stat().st_mode | 0o111)

    print(f"staged {descriptor['package']} {version} at {platform_destination}")


def pack(output_root: Path, pack_output: Path, platform: str) -> None:
    npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
    if npm is None:
        raise SystemExit("npm is required to pack the staged packages")
    pack_output.mkdir(parents=True, exist_ok=True)
    for directory in (ROOT_PACKAGE_DIR, PLATFORMS[platform]["directory"]):
        subprocess.run(
            [npm, "pack", "--ignore-scripts", "--pack-destination", str(pack_output.resolve()),
             str((output_root / directory).resolve())],
            check=True, shell=False,
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path("mcp-cli/npm"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--pack-output", type=Path, help="also create npm tarballs here (no Cargo)")
    args = parser.parse_args(argv)
    stage(args.source_root, args.output, args.platform, args.binary, args.version)
    if args.pack_output is not None:
        pack(args.output, args.pack_output, args.platform)
    return 0


if __name__ == "__main__":
    sys.exit(main())
