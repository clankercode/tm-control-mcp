"""Test recovery transport and safe loaded-dependent ordering."""
import json
from pathlib import Path
import sys
from unittest import mock

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from verify_call_guard import dependent_order
import call as client


class Socket:
    def __init__(self, response):
        self.payload = b''
        self.response = (json.dumps(response) + '\n').encode()

    def __enter__(self): return self
    def __exit__(self, *_): pass
    def settimeout(self, *_): pass
    def sendall(self, payload): self.payload = payload
    def shutdown(self, *_): pass

    def recv(self, *_):
        response, self.response = self.response, b''
        return response


def test_transitive_loaded_dependents_in_provider_order():
    plugins = [
        {'id': 'consumer', 'dependencies': ['provider', 'tm-control-mcp']},
        {'id': 'unrelated', 'dependencies': ['Other']},
        {'id': 'provider', 'dependencies': ['tm-control-mcp']},
    ]
    assert [p['id'] for p in dependent_order(plugins)] == ['provider', 'consumer']


def test_recover_cli_preserves_route_and_uses_instance(capsys):
    response = {'ok': True, 'data': {'success': True}}
    sock = Socket(response)
    with mock.patch.object(sys, 'argv', ['call.py', '--skip-process-check', 'recover', '{"instance":"test-instance","route":"call","tool":"PlaceBlock"}']), \
         mock.patch.object(client.socket, 'create_connection', return_value=sock):
        assert client.main() == 0
    assert json.loads(sock.payload) == {'route': 'recover', 'instance': 'test-instance'}
    captured = capsys.readouterr()
    assert json.loads(captured.out) == response
    assert captured.err == ''


@pytest.mark.parametrize('route,code,hint', [
    ('recover', 'stale_instance', 'Use the current instance token from status.'),
    ('recover', 'reload_failed', 'Reload the plugin manually.'),
    ('GetMode', 'tool_terminated', 'Retry the tool.'),
])
def test_cli_structured_errors_preserve_response_and_exit_status(route, code, hint, capsys):
    result = {'success': False, 'code': code, 'hint': hint, 'error': 'Rejected'}
    response = {'ok': True, 'data': result if route == 'recover' else {'result': result}}
    sock = Socket(response)
    with mock.patch.object(sys, 'argv', ['call.py', '--skip-process-check', route, '{"instance":"test-instance"}']), \
         mock.patch.object(client.socket, 'create_connection', return_value=sock):
        assert client.main() == 0

    expected = ({'route': 'recover', 'instance': 'test-instance'} if route == 'recover'
                else {'route': 'call', 'tool': route, 'input': {'instance': 'test-instance'}})
    assert json.loads(sock.payload) == expected
    captured = capsys.readouterr()
    assert json.loads(captured.out) == response
    assert captured.err == f'[tm-control-mcp] code={code} hint={hint}\n'


@pytest.mark.parametrize('input_json,json_type', [
    ('[]', 'array'),
    ('null', 'null'),
    ('"token"', 'string'),
    ('123', 'number'),
    ('true', 'boolean'),
])
def test_recover_cli_rejects_non_object_json_before_transport(input_json, json_type, capsys):
    with mock.patch.object(sys, 'argv', ['call.py', 'recover', input_json]), \
         mock.patch.object(client, 'find_trackmania_pids') as find_pids, \
         mock.patch.object(client.socket, 'create_connection') as connect:
        assert client.main() == 2
    find_pids.assert_not_called()
    connect.assert_not_called()
    captured = capsys.readouterr()
    assert captured.out == ''
    assert captured.err == f'invalid input for recover: input must be an object, got {json_type}\n'
