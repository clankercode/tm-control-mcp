#!/usr/bin/env python3
"""Build the static Pages artifact and its stable-version discovery file."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]
STABLE_VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


def stable_version(value: str) -> tuple[int, int, int]:
    match = STABLE_VERSION.fullmatch(value.strip())
    if not match:
        raise ValueError(f"Not a stable X.Y.Z version: {value!r}")
    return tuple(int(part) for part in match.groups())


def latest_tagged_version(root: Path = ROOT) -> str:
    """Never publish a branch's untagged version or a prerelease as stable."""
    tags = subprocess.check_output(
        ["git", "tag", "--list"], cwd=root, text=True
    ).splitlines()
    candidates = [(stable_version(tag), tag) for tag in tags if STABLE_VERSION.fullmatch(tag)]
    if not candidates:
        raise ValueError("No stable version tag found; fetch tags before building Pages")
    version, tag = max(candidates)
    manifest = subprocess.check_output(
        ["git", "show", f"{tag}:info.toml"], cwd=root, text=True
    )
    declared = tomllib.loads(manifest)["meta"]["version"]
    if stable_version(declared) != version:
        raise ValueError(f"Tag {tag} disagrees with its info.toml version {declared!r}")
    return ".".join(map(str, version))


def build_site(source: Path, destination: Path, version: str) -> None:
    version = ".".join(map(str, stable_version(version)))
    source, destination = source.resolve(), destination.resolve()
    if destination == source or destination in source.parents or source in destination.parents:
        raise ValueError("Site source and output must be separate, non-nested directories")
    if not (source / "index.html").is_file():
        raise ValueError(f"Missing site entrypoint: {source / 'index.html'}")
    if any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("Site sources must not contain symlinks")
    destination.mkdir(parents=True, exist_ok=True)
    # Remove old outputs so deleted public files cannot survive the next build.
    for child in destination.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()
    shutil.copytree(
        source, destination, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("*.md", "og-source.html", "node_modules", ".*"),
    )
    (destination / "latest-version.txt").write_text(version + "\n", encoding="utf-8")
    (destination / ".nojekyll").touch()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "site")
    parser.add_argument("--output", type=Path, default=ROOT / "_site")
    parser.add_argument("--version", help="Explicit stable version for a local preview")
    args = parser.parse_args()
    version = args.version if args.version is not None else latest_tagged_version()
    build_site(args.source, args.output, version)
    print(f"Built {args.output}: latest-version.txt = {version}")


if __name__ == "__main__":
    main()
