#!/usr/bin/env python3
"""Run a generated TestKit suite. Exit 0 pass, 1 test failure, 2 infrastructure.

Reload mode snapshots raw log bytes before invoking RemoteBuild and accepts only
fresh, complete BEGIN / per-test result / SUITE records. A replaced, truncated or
rewritten log aborts conservatively; rerun after rotation. --log-cmd is a shell
command returning the complete raw log on stdout, so ssh/cat works unchanged.
Tool mode requires successful tm-control dispatch even when assertions fail.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time

from gen_registry import check_registry


class InfrastructureError(ValueError):
    pass


def command_output(command, timeout, shell=False):
    try:
        with subprocess.Popen(command, shell=shell, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=(os.name == 'posix')) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as exc:
                if os.name == 'posix':
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.communicate()
                raise InfrastructureError('command timed out') from exc
            if process.returncode:
                error = stderr.decode('utf-8', errors='replace').strip()
                raise InfrastructureError(f'command exited {process.returncode}: {error}')
            return stdout
    except OSError as exc:
        raise InfrastructureError(f'command failed: {exc}') from exc


class FreshLog:
    """Read local fresh bytes by offset; remote commands return a virtual log.

    For a large remote log, use a helper returning bytes after one fixed offset
    captured before this runner starts. The helper must fail if its source is
    rotated/truncated. It can return that same growing suffix on each poll.
    """
    def __init__(self, path, command, timeout):
        self.path = path
        self.command = command
        self.timeout = timeout
        self.pending = b''
        if command:
            self.previous = command_output(command, timeout, shell=True)
            self.discard_partial = bool(self.previous and not self.previous.endswith(b'\n'))
        else:
            with path.open('rb') as stream:
                stat = os.fstat(stream.fileno())
                self.identity = (stat.st_dev, stat.st_ino)
                self.offset = stat.st_size
                self.head = stream.read(min(64, self.offset))
                stream.seek(max(0, self.offset - 64))
                self.anchor = stream.read(self.offset - stream.tell())
                self.discard_partial = bool(self.anchor and not self.anchor.endswith(b'\n'))

    def lines(self, timeout):
        if self.command:
            current = command_output(self.command, timeout, shell=True)
            if not current.startswith(self.previous):
                raise InfrastructureError('log rotated, truncated or rewritten during run; rerun against the current log')
            fresh = current[len(self.previous):]
            self.previous = current
        else:
            with self.path.open('rb') as stream:
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                if identity != self.identity or stat.st_size < self.offset:
                    raise InfrastructureError('log rotated or truncated during run; rerun against the current log')
                head = stream.read(len(self.head))
                stream.seek(self.offset - len(self.anchor))
                anchor = stream.read(len(self.anchor))
                if head != self.head or anchor != self.anchor:
                    raise InfrastructureError('log rewritten during run; rerun against the current log')
                fresh = stream.read()
                self.offset += len(fresh)
                self.anchor = (self.anchor + fresh)[-64:]
        if self.discard_partial:
            _, separator, fresh = fresh.partition(b'\n')
            if not separator:
                return []
            self.discard_partial = False
        self.pending += fresh
        parts = self.pending.split(b'\n')
        self.pending = parts.pop()
        return [line.decode('utf-8', errors='replace').rstrip('\r') for line in parts]


class LogResults:
    def __init__(self, suite, names):
        self.suite = suite
        self.names = set(names)
        self.started = False
        self.results = {}

    def feed(self, line):
        if 'SELFCHECK ' not in line:
            return None
        marker = line.split('SELFCHECK ', 1)[1]
        # Ignore other suites in a shared Openplanet log.
        kind, sep, payload = marker.partition(': ')
        if not sep:
            return None
        target = payload.split(' / ', 1)[0].split(',', 1)[0]
        if target != self.suite:
            return None
        if kind == 'BEGIN':
            if self.started or payload != f'{self.suite}, {len(self.names)} registered':
                raise InfrastructureError(f'invalid/overlapping BEGIN: {payload}')
            self.started = True
        elif kind in ('PASS', 'FAIL'):
            if not self.started:
                raise InfrastructureError('test result before fresh BEGIN')
            parts = payload.split(' / ', 2)
            if len(parts) != (3 if kind == 'FAIL' else 2):
                raise InfrastructureError(f'malformed {kind}: {payload}')
            name = parts[1]
            if name not in self.names or name in self.results or (kind == 'FAIL' and not parts[2].strip()):
                raise InfrastructureError(f'unknown, duplicate or malformed test result: {payload}')
            self.results[name] = (kind == 'PASS', parts[2] if kind == 'FAIL' else '')
        elif kind == 'SUITE':
            if not self.started:
                raise InfrastructureError('summary before fresh BEGIN')
            match = re.fullmatch(re.escape(self.suite) + r', (\d+) passed, (\d+) failed', payload)
            if not match or set(self.results) != self.names:
                raise InfrastructureError('malformed/incomplete suite summary')
            passed, failed = map(int, match.groups())
            actual_passed = sum(ok for ok, _ in self.results.values())
            if passed != actual_passed or failed != len(self.names) - actual_passed:
                raise InfrastructureError('summary counts do not match per-test results')
            return self.results
        else:
            raise InfrastructureError(f'unknown SELFCHECK marker: {kind}')
        return None


def validate_tool_output(output, suite, names):
    if not isinstance(output, dict) or output.get('suite') != suite:
        raise InfrastructureError('tool returned the wrong suite or a non-object output')
    for key in ('registered', 'passed', 'failed'):
        if type(output.get(key)) is not int or output[key] < 0:
            raise InfrastructureError(f'tool has invalid {key} count')
    if output['registered'] != len(names) or output['passed'] + output['failed'] != len(names):
        raise InfrastructureError('tool counts do not match the current registry')
    failures = output.get('failures')
    if not isinstance(failures, list) or len(failures) != output['failed']:
        raise InfrastructureError('tool failures do not match failed count')
    results = {name: (True, '') for name in names}
    seen = set()
    for failure in failures:
        if not isinstance(failure, str):
            raise InfrastructureError('tool failure must be a string')
        name, separator, reason = failure.partition(' / ')
        if not separator or name not in results or name in seen or not reason.strip():
            raise InfrastructureError(f'unknown, duplicate or malformed tool failure: {failure}')
        seen.add(name)
        results[name] = (False, reason)
    return results


def run_tool(args, suite, names):
    if not args.call_script.is_file():
        raise InfrastructureError(f'call script not found: {args.call_script}; specify --call-script')
    raw = command_output([sys.executable, str(args.call_script), '--skip-process-check',
                          '--host', args.socket_host, '--port', str(args.socket_port),
                          '--timeout', str(args.timeout), args.via_tool_pack,
                          json.dumps({})], args.timeout)
    response = json.loads(raw)
    if not isinstance(response, dict) or response.get('ok') is not True:
        raise InfrastructureError('tm-control transport failed')
    data = response.get('data')
    result = data.get('result') if isinstance(data, dict) else None
    if not isinstance(result, dict) or result.get('success') is not True:
        raise InfrastructureError('tool dispatch failed')
    return validate_tool_output(result.get('output'), suite, names)


def raw_reload(host, port, plugin_id, timeout):
    """RemoteBuild: unframed JSON request; uint32-LE length-prefixed reply."""
    request = {'route': 'load_plugin', 'data': {'id': plugin_id, 'source': 'user', 'type': 'folder'}}
    deadline = time.monotonic() + timeout
    with socket.create_connection((host, port), timeout=timeout) as stream:
        stream.sendall(json.dumps(request).encode('utf-8'))
        def read_exact(count):
            data = b''
            while len(data) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise InfrastructureError('RemoteBuild response timed out')
                stream.settimeout(remaining)
                chunk = stream.recv(count - len(data))
                if not chunk:
                    raise InfrastructureError('RemoteBuild closed before complete response')
                data += chunk
            return data
        length = struct.unpack('<I', read_exact(4))[0]
        if not 0 < length <= 1024 * 1024:
            raise InfrastructureError('invalid RemoteBuild response length')
        response = json.loads(read_exact(length))
    if not isinstance(response, dict) or not response or response.get('error'):
        raise InfrastructureError(f'RemoteBuild rejected load: {response}')


def reload_plugin(args, remaining):
    executable = shutil.which('tm-remote-build')
    if executable:
        command = [executable, 'load', 'folder', args.plugin_id,
                   '--host', args.host, '--port', str(args.port)]
        # RemoteBuild's own log monitor must never auto-detect a different
        # local game when --log-cmd targets a remote host.
        command += ['--op-dir', str(args.log.parent if args.log else args.plugin_dir)]
        command_output(command, remaining)
    else:
        raw_reload(args.host, args.port, args.plugin_id, remaining)


def run_reload(args, suite, names):
    deadline = time.monotonic() + args.timeout
    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise InfrastructureError('timed out waiting for a fresh complete TestKit suite')
        return value
    log = FreshLog(args.log, args.log_cmd, remaining())
    reload_plugin(args, remaining())
    parser = LogResults(suite, names)
    while True:
        for line in log.lines(remaining()):
            result = parser.feed(line)
            if result is not None:
                return result
        time.sleep(min(args.poll_interval, remaining()))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin-dir', type=Path, required=True)
    parser.add_argument('--plugin-id', required=True, help='installed folder plugin ID')
    parser.add_argument('--suite', help='defaults to --plugin-id')
    logs = parser.add_mutually_exclusive_group()
    logs.add_argument('--log', type=Path, help='Openplanet.log path')
    logs.add_argument('--log-cmd', help='shell command returning the complete remote log as bytes')
    parser.add_argument('--host', default='127.0.0.1', help='RemoteBuild host')
    parser.add_argument('--port', type=int, default=30000, help='RemoteBuild port')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--poll-interval', type=float, default=0.2)
    parser.add_argument('--via-tool-pack', help='qualified tool name, e.g. example.RunSelfChecks')
    parser.add_argument('--call-script', type=Path, default=Path(__file__).resolve().parents[2] / 'tools/call.py')
    parser.add_argument('--socket-host', default='127.0.0.1')
    parser.add_argument('--socket-port', type=int, default=30006)
    args = parser.parse_args(argv)
    suite = args.suite or args.plugin_id
    try:
        if not all(math.isfinite(value) and value > 0 for value in (args.timeout, args.poll_interval)):
            raise InfrastructureError('--timeout and --poll-interval must be finite and positive')
        if not re.fullmatch(r'[A-Za-z0-9_.:-]+', suite):
            raise InfrastructureError('suite must contain only letters, numbers, underscore, dot, colon or hyphen')
        if not args.via_tool_pack and not (args.log or args.log_cmd):
            raise InfrastructureError('reload mode requires --log or --log-cmd')
        names = [case.name for case in check_registry(args.plugin_dir)]
        results = run_tool(args, suite, names) if args.via_tool_pack else run_reload(args, suite, names)
    # ValueError includes registry/schema/Unicode errors and numeric conversion
    # limits from log counts and both JSON decoders. Keep the digit limit intact.
    except (OSError, ValueError) as exc:
        print(f'TestKit infrastructure: {exc}', file=sys.stderr)
        return 2
    print(f'{"RESULT":<8} TEST')
    for name, (ok, reason) in sorted(results.items()):
        print(f'{"PASS" if ok else "FAIL":<8} {name}' + (f' / {reason}' if reason else ''))
    failed = sum(not ok for ok, _ in results.values())
    print(f'{suite}: {len(results) - failed} passed, {failed} failed ({len(results)} registered)')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
