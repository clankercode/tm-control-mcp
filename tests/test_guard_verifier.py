"""Exercise verifier recovery failures with a fake transport, never a game."""
import copy
import json
from pathlib import Path
import sys
import threading

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import verify_call_guard as verifier


def plugin(plugin_id, dependencies, *, enabled=True, source='UserFolder', kind='Zip'):
    basename = plugin_id + ('.op' if kind == 'Zip' else '')
    return {'id': plugin_id, 'dependencies': dependencies, 'enabled': enabled,
            'source': source, 'type': kind, 'sourcePathBase': basename,
            'sourcePath': '/plugins/' + basename}


class Bridge:
    def __init__(self, evidence, scenario='success'):
        self.evidence = evidence
        self.scenario = scenario
        self.provider = plugin('provider.op', ['tm-control-mcp'],
                               source='ApplicationFolder', kind='Folder')
        self.consumer = plugin('dips++-dev', ['provider.op'], enabled=False)
        self.snapshot = [self.provider, self.consumer]
        self.plugins = [self.consumer, plugin('unrelated', [], enabled=False), self.provider]
        self.current = {}
        self.requests = []
        self.faults = []
        self.writes = []
        self.wait_started = threading.Event()
        self.wait_done = threading.Event()
        self.forever = False
        self.recovering = False
        self.bad_forever_result = False

    def saved(self):
        return json.loads(self.evidence.read_text())

    def assert_retained(self, record):
        assert record['snapshot'] == self.snapshot
        assert record['originalInstance'] == 'original-instance'
        assert record['original']['instance'] == 'original-instance'

    def __call__(self, host, port, timeout, payload):
        self.requests.append(copy.deepcopy(payload))
        route = payload['route']
        if route == 'status':
            if self.forever and self.scenario == 'status_outage':
                raise OSError('status unavailable after forever')
            if self.recovering and self.scenario == 'reload_deadline':
                raise OSError('reloaded bridge unavailable')
            quarantined = self.forever and not self.recovering
            data = {'calls': {
                'instance': 'new-instance' if self.recovering else 'original-instance',
                'recoveryRequired': quarantined,
                'expiredWorkers': [{'id': 1}] if quarantined else [],
                'active': ([{'tool': 'DevCallGuardProbe'}]
                           if self.wait_started.is_set() and not self.wait_done.is_set() else []),
            }}
        elif route == 'recover':
            if payload['instance'] == 'wrong':
                data = {'success': False, 'code': 'stale_instance'}
            else:
                assert payload['instance'] == 'original-instance'
                self.assert_retained(self.saved())
                assert self.saved()['cleanup']['state'] == 'requesting_reload'
                self.recovering = True
                data = {'success': True, 'output': {'reloadQueued': True}}
        else:
            name, args = payload['tool'], payload['input']
            result = {'success': True}
            if name == 'ListPlugins':
                assert args == {'includeSourcePath': True, 'includeDisabled': True}
                result['output'] = {'plugins': copy.deepcopy(self.plugins)}
            elif name == 'DevCallGuardProbe':
                action = args.get('action', 'ok')
                if action in {'throw', 'die', 'reenter', 'forever'}:
                    # Read the actual file at fault admission, not an in-memory spy.
                    self.assert_retained(self.saved())
                    assert self.writes[0]['phase'] == 'snapshot'
                    assert self.writes[0]['cleanup']['state'] == 'not_started'
                    self.faults.append(action)
                if action == 'wait':
                    self.wait_started.set()
                    assert self.wait_done.wait(2), 'mock interleaved waiter was never released'
                if action == 'forever':
                    self.forever = True
                    result = {'success': False, 'code': 'wrong' if self.bad_forever_result else 'tool_timeout'}
                elif action in {'throw', 'die', 'reenter'}:
                    result = {'success': False, 'code': {
                        'throw': 'tool_exception', 'die': 'tool_terminated',
                        'reenter': 'reentrant_tool'}[action]}
            elif name == 'WaitUntil':
                self.wait_done.set()
            elif name == 'GetPlugin':
                assert set(args) == {'id', 'includeSourcePath'}
                assert args['includeSourcePath'] is True
                observed = self.current[args['id']]
                if self.scenario == 'wrong_identity':
                    observed = {**observed, 'source': 'UserFolder'}
                result['output'] = copy.deepcopy(observed)
            elif name == 'ControlPlugin':
                assert 'includeSourcePath' not in args  # Rejected by the live schema.
                action, plugin_id = args['action'], args['id']
                if self.forever and not self.recovering:
                    result = {'success': False, 'code': 'recovery_required'}
                elif action == 'load':
                    self.assert_retained(self.saved())
                    assert self.saved()['cleanup']['currentPlugin'] == plugin_id
                    assert self.saved()['cleanup']['state'] == 'loading'
                    if self.scenario == 'failed_load' and plugin_id == self.consumer['id']:
                        result = {'success': False, 'code': 'load_failed'}
                    else:
                        original = next(p for p in self.snapshot if p['id'] == plugin_id)
                        self.current[plugin_id] = {**original, 'enabled': True}
                        result['output'] = {'compile': {'loaded': True, 'errorCount': 0}}
                elif action == 'setEnabled':
                    self.current[plugin_id]['enabled'] = args['enabled']
                elif action == 'status':
                    observed = self.current.get(plugin_id, self.consumer)
                    result['output'] = copy.deepcopy(observed)
                else:
                    raise AssertionError(f'unexpected action: {action}')
            else:
                raise AssertionError(f'unexpected tool: {name}')
            data = {'result': result}
        return {'ok': True, 'data': data}


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    bridge = Bridge(tmp_path / 'evidence.json')
    monkeypatch.setattr(sys, 'argv', ['verify_call_guard.py', '--evidence', str(bridge.evidence)])
    monkeypatch.setattr(verifier, 'find_trackmania_pids', lambda: [123])
    monkeypatch.setattr(verifier, 'send_request', bridge)
    now = [0.0]
    monkeypatch.setattr(verifier.time, 'monotonic', lambda: now[0])
    monkeypatch.setattr(verifier.time, 'sleep', lambda seconds: now.__setitem__(0, now[0] + seconds))
    write = verifier.atomic_write_evidence

    def save(path, record):
        write(path, record)
        bridge.writes.append(json.loads(path.read_text()))

    monkeypatch.setattr(verifier, 'atomic_write_evidence', save)
    return bridge


@pytest.mark.parametrize('scenario,error,message,failed_at', [
    ('status_outage', OSError, 'status unavailable after forever', 'checking_status'),
    ('reload_deadline', RuntimeError, 'bridge reload not confirmed', 'waiting_reload'),
    ('failed_load', AssertionError, 'load_failed', 'loading'),
])
def test_recovery_failures_keep_original_snapshot(runtime, scenario, error, message, failed_at):
    runtime.scenario = scenario
    with pytest.raises(error, match=message):
        verifier.main()
    assert 'forever' in runtime.faults
    record = runtime.saved()
    runtime.assert_retained(record)
    assert record['phase'] == 'failed'
    assert record['cleanup']['state'] == 'failed'
    assert record['cleanup']['failedAt'] == failed_at
    assert record['cleanup']['error']['type'] == error.__name__
    assert record['failure']['type'] == error.__name__
    if scenario == 'failed_load':
        assert record['cleanup']['restored'] == [runtime.provider['id']]
        assert record['cleanup']['currentPlugin'] == runtime.consumer['id']
    if scenario == 'status_outage':
        assert any('error' in exchange for exchange in record['exchanges'])


def test_success_restores_exact_descriptors_and_disabled_flag(runtime):
    verifier.main()
    record = runtime.saved()
    runtime.assert_retained(record)
    assert record['phase'] == 'complete'
    assert record['cleanup']['state'] == 'complete'
    assert record['cleanup']['newInstance'] == 'new-instance'
    assert record['cleanup']['restored'] == [p['id'] for p in runtime.snapshot]
    controls = [p['input'] for p in runtime.requests if p.get('tool') == 'ControlPlugin']
    loads = [args for args in controls if args['action'] == 'load']
    assert loads == [
        {'action': 'load', 'id': p['id'], 'path': p['sourcePath'] + ('/' if p['type'] == 'Folder' else ''),
         'source': p['source'], 'type': p['type']} for p in runtime.snapshot]
    assert [args['enabled'] for args in controls if args['action'] == 'setEnabled'] == [True, False]
    assert runtime.current[runtime.consumer['id']]['enabled'] is False
    descriptors = [p['input'] for p in runtime.requests if p.get('tool') == 'GetPlugin']
    assert descriptors == [{'id': p['id'], 'includeSourcePath': True}
                           for p in runtime.snapshot for _ in range(2)]


def test_identity_mismatch_stops_before_enabled_mutation_or_next_load(runtime):
    runtime.scenario = 'wrong_identity'
    with pytest.raises(verifier.UnknownState, match='identity changed'):
        verifier.main()
    runtime.assert_retained(runtime.saved())
    assert runtime.saved()['cleanup']['failedAt'] == 'checking_identity'
    mutations = [p['input'] for p in runtime.requests if p.get('tool') == 'ControlPlugin'
                 and p['input']['action'] in {'load', 'setEnabled'}]
    assert [args['action'] for args in mutations] == ['load']


def test_probe_error_survives_cleanup_failure_and_both_are_saved(runtime):
    runtime.scenario = 'status_outage'
    runtime.bad_forever_result = True
    with pytest.raises(AssertionError):
        verifier.main()
    record = runtime.saved()
    runtime.assert_retained(record)
    assert record['failure']['type'] == 'AssertionError'
    assert record['cleanup']['error']['type'] == 'OSError'


def test_later_write_failures_preserve_early_snapshot_and_primary_error(runtime, monkeypatch, capsys):
    runtime.scenario = 'status_outage'
    save = verifier.atomic_write_evidence
    attempts = []

    def failing_save(path, record):
        attempts.append(record['cleanup']['state'])
        if runtime.forever:
            raise PermissionError('evidence disk unavailable')
        save(path, record)

    monkeypatch.setattr(verifier, 'atomic_write_evidence', failing_save)
    with pytest.raises(OSError, match='status unavailable after forever'):
        verifier.main()
    runtime.assert_retained(runtime.saved())
    assert attempts[-1] == 'failed'  # Outer finally still attempted after cleanup failed.
    assert runtime.saved()['phase'] == 'probe:forever'
    assert 'evidence disk unavailable' in capsys.readouterr().err


@pytest.mark.parametrize('destination', ['missing_parent', 'directory'])
def test_unwritable_destination_prevents_all_faults(runtime, destination, monkeypatch):
    path = runtime.evidence.parent / 'absent' / 'evidence.json' if destination == 'missing_parent' else runtime.evidence.parent
    monkeypatch.setattr(sys, 'argv', ['verify_call_guard.py', '--evidence', str(path)])
    with pytest.raises(OSError):
        verifier.main()
    assert not runtime.faults
    assert [p.get('tool', p['route']) for p in runtime.requests] == ['status', 'ListPlugins']


@pytest.mark.parametrize('malformed', ['identity', 'enabled', 'dependencies', 'duplicate'])
def test_invalid_snapshot_prevents_all_faults(runtime, malformed):
    if malformed == 'identity':
        runtime.provider.pop('sourcePath')
    elif malformed == 'enabled':
        runtime.provider['enabled'] = 0
    elif malformed == 'dependencies':
        runtime.provider['dependencies'] = 'tm-control-mcp'
    else:
        runtime.plugins.append(copy.deepcopy(runtime.provider))
    with pytest.raises(verifier.UnknownState):
        verifier.main()
    assert not runtime.faults
    assert not runtime.evidence.exists()


@pytest.mark.parametrize('operation', ['replace', 'fsync'])
def test_interrupted_atomic_write_keeps_last_complete_record(tmp_path, monkeypatch, operation):
    path = tmp_path / 'evidence.json'
    previous = {'originalInstance': 'original', 'snapshot': [{'id': 'retained'}]}
    verifier.atomic_write_evidence(path, previous)

    def fail(*args):
        if operation == 'replace':
            # The new file is complete before the atomic replacement is attempted.
            assert json.loads(Path(args[0]).read_text()) == {'replacement': True}
        raise OSError('interrupted write')

    monkeypatch.setattr(verifier.os, operation, fail)
    with pytest.raises(OSError, match='interrupted write'):
        verifier.atomic_write_evidence(path, {'replacement': True})
    assert json.loads(path.read_text()) == previous
    assert list(tmp_path.iterdir()) == [path]
