import json
import io
from contextlib import redirect_stdout, redirect_stderr
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import gen_registry as gen
import run_plugin_tests as run


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plugin = self.root / 'plugin'
        (self.plugin / 'src').mkdir(parents=True)
        (self.plugin / 'src/Tests.as').write_text('namespace Tests {\n// [TestKit]\nvoid One(TestKit::Ctx@ ctx) {}\n// [TestKit]\nvoid Two(TestKit::Ctx@ ctx) {}\n}')
        gen.generate(self.plugin)
        self.log = self.root / 'Openplanet.log'
        self.log.write_bytes(b'old UTF-8: \xc3\xa9\n' + self.markers().encode())
        self.args = ['--plugin-dir', str(self.plugin), '--plugin-id', 'sample', '--log', str(self.log), '--timeout', '0.3', '--poll-interval', '0.01']

    def markers(self, fail=False):
        return ('SELFCHECK BEGIN: sample, 2 registered\n'
                'SELFCHECK PASS: sample / Tests::One\n' +
                ('SELFCHECK FAIL: sample / Tests::Two / deliberately broken\n' if fail else 'SELFCHECK PASS: sample / Tests::Two\n') +
                f'SELFCHECK SUITE: sample, {1 if fail else 2} passed, {1 if fail else 0} failed\n')

    def fake_reloader(self, text, code=0, rotation=False):
        executable = self.root / 'tm-remote-build'
        executable.write_text('#!' + sys.executable + '\nimport pathlib, sys\n' +
                              f'p = pathlib.Path({str(self.log)!r})\n' +
                              ("p.unlink()\np.write_bytes(b'')\n" if rotation else '') +
                              f'with p.open("ab") as f: f.write({text.encode()!r})\n' +
                              f'sys.exit({code})\n')
        executable.chmod(0o755)
        return executable

    def invoke(self, text='', code=0, rotation=False, extra=()):
        self.fake_reloader(text, code, rotation)
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get('PATH', ''))
        return subprocess.run([sys.executable, str(ROOT / 'run_plugin_tests.py'), *self.args, *extra], env=env, capture_output=True, text=True)

    def test_cli_pass_and_test_failure(self):
        result = self.invoke(self.markers())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Tests::One', result.stdout)
        result = self.invoke(self.markers(True))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('deliberately broken', result.stdout)

    def test_stale_log_timeout_process_failure_and_rotation(self):
        for kwargs in ({}, {'text': self.markers(), 'code': 7}, {'text': self.markers(), 'rotation': True}):
            with self.subTest(kwargs=kwargs):
                self.log.write_bytes(b'old utf8 \xc3\xa9\n' + self.markers().encode())
                result = self.invoke(**kwargs)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_missing_stale_and_empty_registry_never_reload(self):
        for text in ('stale', ''):
            (self.plugin / 'src/_TestRegistry.as').write_text(text)
            result = self.invoke(self.markers())
            self.assertEqual(result.returncode, 2)
            self.assertIn('registry drift', result.stderr)
        (self.plugin / 'src/Tests.as').write_text('void Main() {}')
        result = self.invoke(self.markers())
        self.assertEqual(result.returncode, 2)
        self.assertIn('no registered tests', result.stderr)

    def test_bad_names_duplicate_counts_and_missing_begin(self):
        for text in (
            self.markers().replace('Tests::Two', 'Tests::Unknown'),
            self.markers().replace('Tests::Two', 'Tests::One'),
            self.markers().replace('2 passed', '1 passed'),
            self.markers().split('\n', 1)[1],
            self.markers().replace('2 registered', '0 registered'),
        ):
            with self.subTest(text=text):
                self.assertEqual(self.invoke(text).returncode, 2)

    def test_remote_log_cmd_fresh_bytes(self):
        self.args = self.args[:4] + ['--log-cmd', f'{sys.executable} -c "import pathlib,sys; sys.stdout.buffer.write(pathlib.Path({str(self.log)!r}).read_bytes())"', '--timeout', '0.4', '--poll-interval', '0.01']
        self.assertEqual(self.invoke(self.markers()).returncode, 0)

    def test_tool_pack_remote_call_contract_and_exit_codes(self):
        call = self.root / 'fake_call.py'
        for failed, expected in ((0, 0), (1, 1)):
            output = {'suite': 'sample', 'registered': 2, 'passed': 2-failed, 'failed': failed,
                      'failures': ['Tests::Two / broken'] if failed else []}
            call.write_text('import json,sys\n'
                            'assert "--skip-process-check" in sys.argv\n'
                            'assert sys.argv[sys.argv.index("--host")+1] == "remote.example"\n'
                            'assert sys.argv[sys.argv.index("--port")+1] == "31234"\n'
                            'assert json.loads(sys.argv[-1]) == {}\n' +
                            f'print({json.dumps({"ok": True, "data": {"result": {"success": True, "output": output}}})!r})\n')
            result = subprocess.run([sys.executable, str(ROOT / 'run_plugin_tests.py'), '--plugin-dir', str(self.plugin), '--plugin-id', 'sample', '--via-tool-pack', 'sample.RunSelfChecks', '--call-script', str(call), '--socket-host', 'remote.example', '--socket-port', '31234'], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
        call.write_text('print("not JSON")')
        result = subprocess.run([sys.executable, str(ROOT / 'run_plugin_tests.py'), '--plugin-dir', str(self.plugin), '--plugin-id', 'sample', '--via-tool-pack', 'sample.RunSelfChecks', '--call-script', str(call)], capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_partial_utf8_lines_and_byte_offset(self):
        self.log.write_bytes(b'old \xc3\xa9\n')
        reader = run.FreshLog(self.log, None, 1)
        with self.log.open('ab') as stream:
            stream.write(b'fresh \xc3')
        self.assertEqual(reader.lines(1), [])
        with self.log.open('ab') as stream:
            stream.write(b'\xa9\n')
        self.assertEqual(reader.lines(1), ['fresh é'])
        self.assertEqual(reader.lines(1), [])

    def test_partial_old_line_is_never_a_fresh_marker(self):
        self.log.write_bytes(b'SELFCHECK BEGIN: sample, ')
        reader = run.FreshLog(self.log, None, 1)
        with self.log.open('ab') as stream:
            stream.write(b'2 registered\nhello\n')
        self.assertEqual(reader.lines(1), ['hello'])

    def test_log_command_failure_and_timeout(self):
        for command in (f'{sys.executable} -c "raise SystemExit(7)"',
                        f'{sys.executable} -c "import time; time.sleep(2)"'):
            with self.subTest(command=command), self.assertRaises(run.InfrastructureError):
                run.FreshLog(None, command, 0.05)

    def test_raw_remotebuild_fallback_framing_and_disconnect(self):
        import struct
        payload = json.dumps({'error': ''}).encode()
        class FakeSocket:
            def __init__(self, data):
                self.data = data
                self.sent = b''
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def settimeout(self, timeout): pass
            def sendall(self, data): self.sent += data
            def recv(self, count):
                chunk, self.data = self.data[:min(count, 2)], self.data[min(count, 2):]
                return chunk
        stream = FakeSocket(struct.pack('<I', len(payload)) + payload)
        with mock.patch.object(run.socket, 'create_connection', return_value=stream):
            run.raw_reload('remote.example', 31234, 'sample', 1)
        self.assertEqual(json.loads(stream.sent), {'route': 'load_plugin', 'data': {'id': 'sample', 'source': 'user', 'type': 'folder'}})
        with mock.patch.object(run.socket, 'create_connection', return_value=FakeSocket(b'')):
            with self.assertRaises(run.InfrastructureError):
                run.raw_reload('remote.example', 31234, 'sample', 1)

    def test_nonfinite_timing_rejected_before_registry_or_live_work(self):
        for option in ('--timeout', '--poll-interval'):
            for value in ('nan', 'inf', '-inf'):
                with self.subTest(option=option, value=value):
                    stderr = io.StringIO()
                    with mock.patch.object(run, 'check_registry', return_value=[] ) as registry, \
                         mock.patch.object(run, 'run_reload', return_value={'fixture': (True, '')}) as reload, \
                         redirect_stdout(io.StringIO()), redirect_stderr(stderr):
                        result = run.main([*self.args, option + '=' + value])
                    self.assertEqual(result, 2)
                    self.assertIn('finite and positive', stderr.getvalue())
                    registry.assert_not_called()
                    reload.assert_not_called()

    def test_tool_schema_rejects_bool_counts_wrong_suite_unknown_failure(self):
        baseline = {'suite': 'sample', 'registered': 2, 'passed': 1, 'failed': 1, 'failures': ['Tests::One / broken']}
        for updates in ({'registered': True}, {'suite': 'other'}, {'passed': 2}, {'failures': ['Unknown / broken']}, {'failures': []}):
            with self.subTest(updates=updates), self.assertRaises(run.InfrastructureError):
                run.validate_tool_output(dict(baseline, **updates), 'sample', ['Tests::One', 'Tests::Two'])


if __name__ == '__main__':
    unittest.main()
