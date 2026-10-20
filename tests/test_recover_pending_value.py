"""Offline recovery validates the whole envelope and never clobbers a backup."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/recover_pending_value.py"


@pytest.fixture
def recovery():
    spec = importlib.util.spec_from_file_location("recover_pending_value", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def envelope(value=b"offline value"):
    return json.dumps([["value", "draft", base64.b64encode(value).decode("ascii")]]).encode()


@pytest.mark.parametrize("raw", [
    b"", b"[", b"{}", b"null", b'"text"', b"[NaN]", b"\xff",
    b"[[]]", b'[["value","draft"]]', b'[["value","draft","YQ==",0]]',
    b'[["value","draft",null]]', b'[[1,"draft","YQ=="]]',
    b'[["value",false,"YQ=="]]', b'[{"type":"value"}]',
    b'[["value","draft","YQ=="],null]',
    b'[["value","draft","YQ=="],["other",1,"Yg=="]]',
])
def test_rejects_malformed_json_and_event_shapes(recovery, raw):
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(raw, event="value", key="draft")


def test_deep_json_is_a_controlled_error(recovery):
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(b"[" * 2000 + b"]" * 2000, event="value", key="draft")


@pytest.mark.parametrize("rows", [
    [], [["different", "draft", "YQ=="]], [["value", "other", "YQ=="]],
    [["value", "draft", "YQ=="], ["value", "draft", "YQ=="]],
    [["value", "draft", "YQ=="], ["value", "draft", "Yg=="]],
])
def test_requires_exactly_one_exact_match(recovery, rows):
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(json.dumps(rows).encode(), event="value", key="draft")


@pytest.mark.parametrize("value", [b"", b"a", b"ab", b"abc", bytes(range(256))])
def test_canonical_decoding_preserves_arbitrary_bytes(recovery, value):
    assert recovery.decode_value(envelope(value), event="value", key="draft") == value


@pytest.mark.parametrize("encoded", [
    "YQ", "YQ=", "YQ===", "YQ==\n", " YQ==", "YQ==!", "YR==", "YWJ=",
    "====", "AA=A", "_w==", "-w==", "é", "YQ==Yg==", "YWJj=", "YWJj====",
])
def test_rejects_noncanonical_base64(recovery, encoded):
    raw = json.dumps([["value", "draft", encoded]]).encode()
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(raw, event="value", key="draft")


@pytest.mark.parametrize("event,key", [
    ("", "draft"), ("value", ""), (None, "draft"), ("value", 1), ("\ud800", "draft"),
])
def test_selectors_are_required_nonempty_strings(recovery, event, key):
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(envelope(), event=event, key=key)


def test_limits_and_exact_boundaries(recovery, monkeypatch):
    raw = envelope(b"abcd")
    monkeypatch.setattr(recovery, "MAX_INPUT_BYTES", len(raw))
    assert recovery.decode_value(raw, event="value", key="draft") == b"abcd"
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(raw + b" ", event="value", key="draft")
    monkeypatch.setattr(recovery, "MAX_OUTPUT_BYTES", 4)
    assert recovery.decode_value(raw, event="value", key="draft") == b"abcd"
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(envelope(b"abcde"), event="value", key="draft")


def test_row_and_selector_limits(recovery, monkeypatch):
    monkeypatch.setattr(recovery, "MAX_EVENTS", 1)
    raw = json.dumps([["other", "draft", ""], ["value", "draft", ""]]).encode()
    with pytest.raises(recovery.RecoveryError):
        recovery.decode_value(raw, event="value", key="draft")
    monkeypatch.setattr(recovery, "MAX_SELECTOR_BYTES", 5)
    assert recovery.decode_value(envelope(), event="value", key="draft") == b"offline value"
    for event, key in [("values", "draft"), ("value", "drafts"), ("ééé", "draft")]:
        with pytest.raises(recovery.RecoveryError):
            recovery.decode_value(envelope(), event=event, key=key)


def test_bounded_file_read_and_no_backup_on_invalid_input(recovery, monkeypatch, tmp_path):
    source, backup = tmp_path / "events.json", tmp_path / "backup.bin"
    source.write_bytes(envelope())
    monkeypatch.setattr(recovery, "MAX_INPUT_BYTES", 16)
    with pytest.raises(recovery.RecoveryError):
        recovery.recover(source, backup, event="value", key="draft")
    assert not backup.exists()


def test_encoded_limit_rejects_before_decoding(recovery, monkeypatch):
    monkeypatch.setattr(recovery, "MAX_OUTPUT_BYTES", 4)

    def unexpected_decode(*args, **kwargs):
        pytest.fail("oversized base64 must be rejected before decoding")

    monkeypatch.setattr(recovery.base64, "b64decode", unexpected_decode)
    with pytest.raises(recovery.RecoveryError, match="encoded value exceeds"):
        recovery.decode_value(envelope(b"1234567"), event="value", key="draft")


def test_row_selector_limits_and_unicode(recovery, monkeypatch):
    monkeypatch.setattr(recovery, "MAX_SELECTOR_BYTES", 5)
    for selector in ["longer", "\ud800", ""]:
        raw = json.dumps([["value", "draft", ""], [selector, "other", ""]]).encode()
        with pytest.raises(recovery.RecoveryError):
            recovery.decode_value(raw, event="value", key="draft")


def test_exclusive_backup_and_digest_only(recovery, tmp_path):
    source, backup = tmp_path / "events.json", tmp_path / "backup.bin"
    value = b"private binary\x00\xff"
    source.write_bytes(envelope(value))
    report = recovery.recover(source, backup, event="value", key="draft")
    assert report == {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}
    assert backup.read_bytes() == value
    assert backup.stat().st_mode & 0o777 == 0o600
    before = source.read_bytes()
    with pytest.raises(recovery.RecoveryError):
        recovery.recover(source, backup, event="value", key="draft")
    assert backup.read_bytes() == value
    assert source.read_bytes() == before
    with pytest.raises(recovery.RecoveryError):
        recovery.recover(source, source, event="value", key="draft")
    assert source.read_bytes() == before


@pytest.mark.parametrize("dangling", [False, True])
def test_existing_symlink_is_never_followed(recovery, tmp_path, dangling):
    source, backup, target = tmp_path / "events.json", tmp_path / "backup.bin", tmp_path / "target"
    source.write_bytes(envelope())
    if not dangling:
        target.write_bytes(b"existing")
    backup.symlink_to(target)
    with pytest.raises(recovery.RecoveryError):
        recovery.recover(source, backup, event="value", key="draft")
    assert backup.is_symlink()
    if dangling:
        assert not target.exists()
    else:
        assert target.read_bytes() == b"existing"


def test_io_errors_do_not_echo_paths_or_create_false_success(recovery, monkeypatch, tmp_path):
    source, backup = tmp_path / "private-input.json", tmp_path / "private-backup.bin"
    with pytest.raises(recovery.RecoveryError, match="^cannot read input file$"):
        recovery.recover(source, backup, event="value", key="draft")
    assert not backup.exists()
    source.write_bytes(envelope())

    def fail_sync(fd):
        raise OSError("sensitive filesystem details")

    monkeypatch.setattr(recovery.os, "fsync", fail_sync)
    with pytest.raises(recovery.RecoveryError, match="^backup write failed; inspect the incomplete backup$"):
        recovery.recover(source, backup, event="value", key="draft")
    assert backup.exists()
    with pytest.raises(recovery.RecoveryError, match="^backup already exists; choose a new path$"):
        recovery.recover(source, backup, event="value", key="draft")


def test_cli_requires_both_selectors_and_does_not_echo_payload(tmp_path):
    source, backup = tmp_path / "events.json", tmp_path / "backup.bin"
    secret = b"payload must stay offline"
    source.write_bytes(envelope(secret))
    for selectors in [[], ["--event", "value"], ["--key", "draft"]]:
        run = subprocess.run([sys.executable, str(SCRIPT), str(source), str(backup), *selectors],
                             capture_output=True, text=True)
        assert run.returncode != 0
        assert not backup.exists()
    command = [sys.executable, str(SCRIPT), str(source), str(backup), "--event", "value", "--key", "draft"]
    run = subprocess.run(command, capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    assert json.loads(run.stdout) == {"bytes": len(secret), "sha256": hashlib.sha256(secret).hexdigest()}
    again = subprocess.run(command, capture_output=True, text=True)
    assert again.returncode != 0
    assert backup.read_bytes() == secret
    source.write_bytes(b'[["value","draft","payload must stay offline"]]')
    invalid = subprocess.run(command, capture_output=True, text=True)
    assert invalid.returncode != 0
    for result in (run, again, invalid):
        assert secret.decode() not in result.stdout + result.stderr
        assert base64.b64encode(secret).decode() not in result.stdout + result.stderr
