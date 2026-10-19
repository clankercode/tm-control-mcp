"""Behavior checks for the release-file/site deployment boundary (no network)."""
from pathlib import Path
import re
import subprocess
import sys
import textwrap

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_site import build_site, latest_tagged_version, stable_version, verify_site


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


@pytest.fixture
def tagged_repo(tmp_path):
    git(tmp_path, "init", "-q")
    git(tmp_path, "config", "user.email", "test@example.invalid")
    git(tmp_path, "config", "user.name", "Test")
    return tmp_path


def tag_version(root, version, tag=None):
    (root / "info.toml").write_text(f'[meta]\nversion = "{version}"\n')
    git(root, "add", "info.toml")
    git(root, "commit", "-qm", version)
    git(root, "tag", tag or "v" + version)


def test_selects_numeric_latest_and_ignores_branch_and_prerelease(tagged_repo):
    tag_version(tagged_repo, "0.9.0")
    tag_version(tagged_repo, "0.10.0", "0.10.0")
    tag_version(tagged_repo, "1.0.0-rc.1")
    (tagged_repo / "info.toml").write_text('[meta]\nversion = "9.0.0"\n')
    assert latest_tagged_version(tagged_repo) == "0.10.0"


def test_mismatched_tag_fails_closed(tagged_repo):
    tag_version(tagged_repo, "0.9.0", "v1.0.0")
    with pytest.raises(ValueError, match="disagrees"):
        latest_tagged_version(tagged_repo)


def test_no_stable_tag_fails_closed(tagged_repo):
    tag_version(tagged_repo, "1.0.0-beta.1")
    with pytest.raises(ValueError, match="No stable version tag"):
        latest_tagged_version(tagged_repo)


def test_site_and_version_coexist_and_stale_outputs_disappear(tmp_path):
    source, output = tmp_path / "source", tmp_path / "output"
    source.mkdir()
    (source / "index.html").write_text("<h1>Site</h1>")
    (source / "favicon.svg").write_text("<svg/>")
    (source / "DESIGN.md").write_text("Private build notes")
    (source / "og-source.html").write_text("Design source")
    output.mkdir()
    (output / "obsolete.html").touch()
    build_site(source, output, "v0.10.0")
    assert (output / "index.html").read_text() == "<h1>Site</h1>"
    assert (output / "favicon.svg").is_file()
    assert (output / "latest-version.txt").read_bytes() == b"0.10.0\n"
    assert (output / ".nojekyll").is_file()
    assert not (output / "obsolete.html").exists()
    assert not (output / "DESIGN.md").exists()
    assert not (output / "og-source.html").exists()


@pytest.mark.parametrize("version", ["", "1.2", "01.2.3", "1.2.3\nmalicious", "1.2.3-rc.1"])
def test_invalid_stable_file_rejected(version):
    with pytest.raises(ValueError):
        stable_version(version)


def test_refuses_nested_output_before_removing_files(tmp_path):
    (tmp_path / "index.html").write_text("Keep me")
    with pytest.raises(ValueError, match="separate"):
        build_site(tmp_path, tmp_path / "output", "0.1.0")
    assert (tmp_path / "index.html").read_text() == "Keep me"


def test_broken_local_assets_and_anchors_fail_the_build(tmp_path):
    index = tmp_path / "index.html"
    index.write_text('<a href="#missing">Section</a>')
    with pytest.raises(ValueError, match="missing anchor"):
        verify_site(tmp_path)
    index.write_text('<link href="absent.css" rel="stylesheet">')
    with pytest.raises(ValueError, match="missing local file"):
        verify_site(tmp_path)
    (tmp_path / "style.css").write_text('@font-face{src:url("font.woff2")}')
    index.write_text('<link href="style.css" rel="stylesheet"><a href="https://example.com">Offsite</a>')
    with pytest.raises(ValueError, match="missing asset"):
        verify_site(tmp_path)
    (tmp_path / "font.woff2").touch()
    verify_site(tmp_path)


def test_copy_paste_template_preserves_site_and_selects_latest(tagged_repo):
    tag_version(tagged_repo, "0.9.0")
    tag_version(tagged_repo, "0.10.0")
    tag_version(tagged_repo, "1.0.0-rc.1")
    template = (Path(__file__).resolve().parents[1] / "docs/templates/pack-pages.yml").read_text()
    match = re.search(r"shell: python\n        run: \|\n(.*?)      - uses:", template, re.S)
    assert match is not None
    output = tagged_repo / "_site"
    output.mkdir()
    (output / "index.html").write_text("A complete existing site")
    subprocess.run([sys.executable, "-c", textwrap.dedent(match[1])], cwd=tagged_repo, check=True)
    assert (output / "latest-version.txt").read_bytes() == b"0.10.0\n"
    assert (output / "index.html").read_text() == "A complete existing site"
