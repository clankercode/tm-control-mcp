#!/usr/bin/env python3
"""Build the static Pages artifact and its stable-version discovery file."""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tomllib
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
STABLE_VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


class PageReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls: list[str] = []
        self.ids: set[str] = set()
        self.social_images: list[str] = []
        self.canonical: str | None = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href")
        if tag == "meta" and (attrs.get("property") == "og:image" or attrs.get("name") == "twitter:image"):
            self.social_images.append(attrs.get("content", ""))
        for key in ("src", "href"):
            if attrs.get(key):
                self.urls.append(attrs[key])


def verify_site(destination: Path) -> None:
    """Fail builds with missing local assets or broken page anchors."""
    refs = PageReferences()
    refs.feed((destination / "index.html").read_text(encoding="utf-8"))
    for reference in refs.urls:
        url = urlsplit(reference)
        if url.scheme or url.netloc:
            continue
        if url.path:
            target = destination / unquote(url.path).lstrip("/")
            if not target.exists():
                raise ValueError(f"Site references missing local file: {reference}")
        elif url.fragment and unquote(url.fragment) not in refs.ids:
            raise ValueError(f"Site references missing anchor: {reference}")
    for css in destination.rglob("*.css"):
        for reference in re.findall(r"url\(\s*['\"]?([^'\")\s]+)", css.read_text(encoding="utf-8")):
            url = urlsplit(reference)
            if not url.scheme and not url.netloc and url.path:
                target = destination / url.path.lstrip("/") if url.path.startswith("/") else css.parent / unquote(url.path)
                if not target.exists():
                    raise ValueError(f"Stylesheet references missing asset: {reference}")
    for image_url in refs.social_images:
        if not refs.canonical or not image_url.startswith(refs.canonical):
            raise ValueError("Social images must use the absolute canonical site URL")
        image_path = destination / unquote(urlsplit(image_url[len(refs.canonical):]).path)
        if not image_path.is_file():
            raise ValueError(f"Missing social image: {image_url}")
        data = image_path.read_bytes()
        if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (1200, 630):
            raise ValueError("Social image must be a 1200x630 PNG")


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
    verify_site(destination)


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
