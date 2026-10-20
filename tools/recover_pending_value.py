#!/usr/bin/env python3
"""Back up one value from a user-supplied offline JSON event array.

Rows must be [event_type, key, canonical_base64_value]. This utility has no
game, plugin, network, or script integration. Stdout contains only byte length
and SHA-256; decoded bytes go exclusively to a newly created backup file.
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import sys

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_EVENTS = 4096
MAX_SELECTOR_BYTES = 1024


class RecoveryError(ValueError):
    """A fixed, payload-free description safe to show on stderr."""


def _selector(value):
    if not isinstance(value, str) or not value:
        raise RecoveryError("event and key must be nonempty strings")
    try:
        length = len(value.encode("utf-8"))
    except UnicodeError:
        raise RecoveryError("event or key is not valid Unicode") from None
    if length > MAX_SELECTOR_BYTES:
        raise RecoveryError("event or key exceeds the byte limit")


def _invalid_constant(_value):
    raise RecoveryError("input is not strict JSON")


def decode_value(raw: bytes, *, event: str, key: str) -> bytes:
    """Validate every row's shape, select exactly once, then decode canonically."""
    _selector(event)
    _selector(key)
    if len(raw) > MAX_INPUT_BYTES:
        raise RecoveryError("input exceeds the byte limit")
    try:
        rows = json.loads(raw.decode("utf-8"), parse_constant=_invalid_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise RecoveryError("input is not valid JSON") from None
    if not isinstance(rows, list):
        raise RecoveryError("input must be a JSON event array")
    if len(rows) > MAX_EVENTS:
        raise RecoveryError("input exceeds the event limit")

    matches = 0
    encoded = ""
    encoded_limit = 4 * ((MAX_OUTPUT_BYTES + 2) // 3)
    for row in rows:
        if not isinstance(row, list) or len(row) != 3 or not all(isinstance(v, str) for v in row):
            raise RecoveryError("each event must contain exactly three strings")
        _selector(row[0])
        _selector(row[1])
        if len(row[2]) > encoded_limit:
            raise RecoveryError("encoded value exceeds the byte limit")
        if row[0] == event and row[1] == key:
            matches += 1
            encoded = row[2]
    if matches != 1:
        raise RecoveryError("expected exactly one matching event and key")
    try:
        ascii_value = encoded.encode("ascii")
        value = base64.b64decode(ascii_value, validate=True)
    except (UnicodeError, binascii.Error, ValueError):
        raise RecoveryError("matching value is not canonical base64") from None
    if len(value) > MAX_OUTPUT_BYTES:
        raise RecoveryError("decoded value exceeds the byte limit")
    # validate=True alone accepts nonzero pad bits and some excess padding.
    if base64.b64encode(value) != ascii_value:
        raise RecoveryError("matching value is not canonical base64")
    return value


def recover(input_path: Path, backup_path: Path, *, event: str, key: str) -> dict:
    try:
        with Path(input_path).open("rb") as source:
            raw = source.read(MAX_INPUT_BYTES + 1)
    except OSError:
        raise RecoveryError("cannot read input file") from None
    value = decode_value(raw, event=event, key=key)
    try:
        # O_EXCL refuses existing files, directories, and even dangling symlinks.
        fd = os.open(backup_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise RecoveryError("backup already exists; choose a new path") from None
    except OSError:
        raise RecoveryError("cannot create backup file") from None
    try:
        with os.fdopen(fd, "wb") as backup:
            backup.write(value)
            backup.flush()
            os.fsync(backup.fileno())
    except OSError:
        # Leave the exclusive file in place; never silently retry or overwrite.
        raise RecoveryError("backup write failed; inspect the incomplete backup") from None
    return {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes unknown arguments, which may contain data.
        self.exit(2, "error: invalid arguments; see --help\n")


def main(argv=None) -> int:
    parser = _Parser(description=__doc__)
    parser.add_argument("input", type=Path, help="offline JSON event array")
    parser.add_argument("backup", type=Path, help="new binary backup path (must not exist)")
    parser.add_argument("--event", required=True, help="exact event type to match")
    parser.add_argument("--key", required=True, help="exact key to match")
    args = parser.parse_args(argv)
    try:
        report = recover(args.input, args.backup, event=args.event, key=args.key)
    except RecoveryError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
