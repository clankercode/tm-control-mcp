#!/usr/bin/env python3
"""Verify MCP CLI npm metadata and staged or packed platform artifacts.

The source-only mode is safe on any developer machine and does not invoke
Cargo. Artifact mode accepts either staged package directories or npm ``.tgz``
files. It checks the executable names, platform metadata, package versions,
and the root launcher's required files.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import stat
import sys
import tarfile


ROOT_PACKAGE_DIR = "tm-control-mcp"
PLATFORMS = {
    "linux-x64": {
        "directory": "tm-control-mcp-linux-x64",
        "package": "@clankercode/tm-control-mcp-linux-x64",
        "os": ["linux"],
        "cpu": ["x64"],
        "binary": "bin/tm-control-mcp",
    },
    "win32-x64": {
        "directory": "tm-control-mcp-win32-x64",
        "package": "@clankercode/tm-control-mcp-win32-x64",
        "os": ["win32"],
        "cpu": ["x64"],
        "binary": "bin/tm-control-mcp.exe",
    },
}
ROOT_PACKAGE = "@clankercode/tm-control-mcp"
LIFECYCLE_KEYS = {"preinstall", "install", "postinstall", "prepare"}


def fail(message: str) -> None:
    raise SystemExit(f"mcp-cli artifact verification failed: {message}")


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")
    raise AssertionError("unreachable")


def check_no_lifecycle_scripts(metadata: dict, label: str) -> None:
    scripts = metadata.get("scripts", {})
    present = sorted(LIFECYCLE_KEYS.intersection(scripts))
    if present:
        fail(f"{label} declares install lifecycle scripts: {', '.join(present)}")


def verify_source(source_root: Path) -> tuple[dict, dict[str, dict]]:
    root_metadata = load_json(source_root / ROOT_PACKAGE_DIR / "package.json")
    expected_optional = {item["package"]: root_metadata.get("version") for item in PLATFORMS.values()}
    if root_metadata.get("name") != ROOT_PACKAGE:
        fail(f"root package name is {root_metadata.get('name')!r}")
    if root_metadata.get("bin", {}).get("tm-control-mcp") != "bin/tm-control-mcp.js":
        fail("root package does not expose bin/tm-control-mcp.js")
    if root_metadata.get("optionalDependencies") != expected_optional:
        fail("root optionalDependencies do not match the two platform packages")
    if "bin" not in root_metadata.get("files", []):
        fail("root package does not include its launcher bin directory")
    check_no_lifecycle_scripts(root_metadata, ROOT_PACKAGE)
    launcher = source_root / ROOT_PACKAGE_DIR / "bin" / "tm-control-mcp.js"
    if not launcher.is_file():
        fail(f"missing launcher {launcher}")
    launcher_text = launcher.read_text(encoding="utf-8")
    for required in ('shell: false', 'stdio: "inherit"', "process.argv.slice(2)"):
        if required not in launcher_text:
            fail(f"launcher is missing required forwarding logic: {required}")

    platform_metadata: dict[str, dict] = {}
    for platform, descriptor in PLATFORMS.items():
        metadata = load_json(source_root / descriptor["directory"] / "package.json")
        label = descriptor["package"]
        if metadata.get("name") != label:
            fail(f"{label} metadata has the wrong name")
        if metadata.get("version") != root_metadata.get("version"):
            fail(f"{label} version differs from the root package")
        if metadata.get("os") != descriptor["os"] or metadata.get("cpu") != descriptor["cpu"]:
            fail(f"{label} does not constrain its platform and CPU")
        if f"./{descriptor['binary']}" not in metadata.get("exports", {}):
            fail(f"{label} does not export {descriptor['binary']}")
        if "bin" not in metadata.get("files", []):
            fail(f"{label} does not include its bin directory")
        check_no_lifecycle_scripts(metadata, label)
        platform_metadata[platform] = metadata
    return root_metadata, platform_metadata


class PackageView:
    def __init__(self, metadata: dict, files: dict[str, tuple[int, bytes | None]]) -> None:
        self.metadata = metadata
        self.files = files


def direct_package(path: Path) -> PackageView:
    metadata = load_json(path / "package.json")
    files: dict[str, tuple[int, bytes | None]] = {}
    for file_path in path.rglob("*"):
        if file_path.is_file():
            relative = file_path.relative_to(path).as_posix()
            files[relative] = (file_path.stat().st_mode, file_path.read_bytes())
    return PackageView(metadata, files)


def tar_package(path: Path) -> PackageView:
    try:
        archive = tarfile.open(path, "r:gz")
    except (OSError, tarfile.TarError) as error:
        fail(f"cannot open npm artifact {path}: {error}")
    with archive:
        members = {member.name: member for member in archive.getmembers() if member.isfile()}
        metadata_member = members.get("package/package.json")
        if metadata_member is None:
            fail(f"npm artifact {path} has no package/package.json")
        metadata = json.loads(archive.extractfile(metadata_member).read().decode("utf-8"))
        files: dict[str, tuple[int, bytes | None]] = {}
        for name, member in members.items():
            if not name.startswith("package/"):
                continue
            relative = name.removeprefix("package/")
            body = archive.extractfile(member).read() if relative != "package.json" else None
            files[relative] = (member.mode, body)
    return PackageView(metadata, files)


def artifact_packages(artifact_root: Path) -> dict[str, PackageView]:
    packages: dict[str, PackageView] = {}
    for directory in artifact_root.iterdir() if artifact_root.exists() else []:
        if directory.is_dir() and (directory / "package.json").is_file():
            package = direct_package(directory)
            packages[package.metadata.get("name", directory.name)] = package
        elif directory.suffix == ".tgz":
            package = tar_package(directory)
            packages[package.metadata.get("name", directory.name)] = package
    return packages


def verify_artifacts(artifact_root: Path, version: str | None, platform: str | None = None,
                     binary_root: Path | None = None) -> None:
    packages = artifact_packages(artifact_root)
    selected = PLATFORMS if platform is None else {platform: PLATFORMS[platform]}
    expected_names = {ROOT_PACKAGE, *(descriptor["package"] for descriptor in selected.values())}
    missing = sorted(expected_names.difference(packages))
    if missing:
        fail(f"artifact root is missing: {', '.join(missing)}")
    for name, package in packages.items():
        if name not in expected_names:
            continue
        if package.metadata.get("version") != (version or packages[ROOT_PACKAGE].metadata.get("version")):
            fail(f"{name} has version {package.metadata.get('version')!r}, expected {version!r}")
        check_no_lifecycle_scripts(package.metadata, name)

    root = packages[ROOT_PACKAGE]
    launcher = root.files.get("bin/tm-control-mcp.js")
    if launcher is None:
        fail("root artifact is missing bin/tm-control-mcp.js")
    if not launcher[1] or not launcher[1].startswith(b"#!/usr/bin/env node\n"):
        fail("root launcher artifact is missing the Node shebang")
    if root.metadata.get("bin") != {"tm-control-mcp": "bin/tm-control-mcp.js"}:
        fail("root artifact has incorrect CLI entrypoint metadata")
    optional_dependencies = root.metadata.get("optionalDependencies", {})
    expected_optional = {descriptor["package"]: root.metadata.get("version") for descriptor in PLATFORMS.values()}
    if optional_dependencies != expected_optional:
        fail("root artifact optionalDependencies do not match its platform package versions")
    for platform_name, descriptor in selected.items():
        package = packages[descriptor["package"]]
        if package.metadata.get("os") != descriptor["os"] or package.metadata.get("cpu") != descriptor["cpu"]:
            fail(f"{descriptor['package']} artifact has incorrect platform metadata")
        if f"./{descriptor['binary']}" not in package.metadata.get("exports", {}):
            fail(f"{descriptor['package']} artifact does not export {descriptor['binary']}")
        binary = package.files.get(descriptor["binary"])
        if binary is None:
            fail(f"{descriptor['package']} is missing {descriptor['binary']}")
        if not binary[1]:
            fail(f"{descriptor['package']} contains an empty binary")
        if binary_root is not None:
            built_binary = binary_root / f"mcp-cli-binary-{platform_name}" / Path(descriptor["binary"]).name
            if not built_binary.is_file() or built_binary.read_bytes() != binary[1]:
                fail(f"{descriptor['package']} does not match downloaded build output {built_binary}")
        if package.metadata.get("bin"):
            fail("platform packages must not compete with the launcher CLI entrypoint")
        if platform_name == "linux-x64" and not binary[0] & stat.S_IXUSR:
            fail("Linux x64 binary is not executable")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path("mcp-cli/npm"))
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--binary-root", type=Path, help="compare tarball bytes with downloaded CI binaries")
    parser.add_argument("--version")
    parser.add_argument("--platform", choices=sorted(PLATFORMS))
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args(argv)
    verify_source(args.source_root)
    if not args.source_only:
        if args.artifact_root is None:
            parser.error("--artifact-root is required unless --source-only is used")
        verify_artifacts(args.artifact_root, args.version, args.platform, args.binary_root)
    print("mcp-cli package metadata and artifacts verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
