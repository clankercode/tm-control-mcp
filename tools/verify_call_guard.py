#!/usr/bin/env python3
"""Live DEV regression: supervised calls, interleaving, death and reload recovery.

Requires exclusive runtime access. Uses only existing plugins, never stages files
or restarts Trackmania. Restores the initially loaded required dependent closure.
The forever-yield fault is always followed by recovery, including assertion errors.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import tempfile
import time

from build_pack_state import UnknownState, check_compile, identity, typed_entries
from call import find_trackmania_pids, send_request


def dependent_order(plugins: list[dict], root: str = 'tm-control-mcp') -> list[dict]:
    """Return only loaded reverse dependents, with providers before consumers."""
    closure = {root}
    while True:
        added = {p['id'] for p in plugins if set(p.get('dependencies', [])) & closure} - closure
        if not added:
            break
        closure |= added
    remaining = [p for p in plugins if p['id'] in (closure - {root})]
    ordered = []
    ready = {root}
    while remaining:
        batch = [p for p in remaining if not ((set(p.get('dependencies', [])) & closure) - ready)]
        if not batch:
            raise RuntimeError('cycle in loaded required dependents')
        ordered.extend(batch)
        ready.update(p['id'] for p in batch)
        remaining = [p for p in remaining if p not in batch]
    return ordered


def validated_snapshot(output: dict) -> list[dict]:
    plugins = typed_entries(output, 'plugins', 'id')
    if len({p['id'] for p in plugins}) != len(plugins):
        raise UnknownState('plugins contains duplicate IDs')
    for plugin in plugins:
        deps = plugin.get('dependencies')
        if not isinstance(deps, list) or any(not isinstance(d, str) or not d for d in deps):
            raise UnknownState('plugin dependencies malformed')
    snapshot = dependent_order(plugins)
    for plugin in snapshot:
        identity(plugin)
    return snapshot


def atomic_write_evidence(path: Path, evidence: dict) -> None:
    """Replace only with a complete, flushed record; keep the last good snapshot."""
    serialized = json.dumps(evidence, indent=2) + '\n'
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix=f'.{path.name}.', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass  # Never hide a write/replace failure during temporary cleanup.


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=30006)
    parser.add_argument('--evidence', type=Path, default=Path('/tmp/tm-call-guard-evidence.json'))
    args = parser.parse_args()
    if not find_trackmania_pids():
        raise RuntimeError('Trackmania.exe is not visible; run outside the shell sandbox')
    exchanges = []

    def request(route: str, **fields) -> dict:
        payload = {'route': route, **fields}
        try:
            response = send_request(args.host, args.port, 70, payload)
        except Exception as exc:
            exchanges.append({'request': payload, 'error': failure(exc)})
            raise
        exchanges.append({'request': payload, 'response': response})
        if not response.get('ok'):
            raise RuntimeError(response)
        return response['data']

    def tool(name: str, **data) -> dict:
        return request('call', tool=name, input=data)['result']

    def status() -> dict:
        return request('status')['calls']

    def failure(exc: BaseException) -> dict:
        return {'type': type(exc).__name__, 'message': str(exc)}

    original = status()
    if original['recoveryRequired'] or original['active']:
        raise RuntimeError('start with an idle healthy bridge; inspect status before recovery')
    if not isinstance(original.get('instance'), str) or not original['instance']:
        raise UnknownState('bridge instance missing or malformed')
    snapshot = validated_snapshot(tool('ListPlugins', includeSourcePath=True,
                                       includeDisabled=True)['output'])
    cleanup = {'state': 'not_started', 'restored': []}
    evidence = {'originalInstance': original['instance'], 'original': original,
                'snapshot': snapshot, 'exchanges': exchanges, 'cleanup': cleanup,
                'phase': 'snapshot', 'evidenceErrors': []}

    def checkpoint(phase: str | None = None, *, required: bool = False) -> None:
        if phase is not None:
            evidence['phase'] = phase
        try:
            atomic_write_evidence(args.evidence, evidence)
        except Exception as exc:
            evidence['evidenceErrors'].append(failure(exc))
            if required:
                raise
            print(f'warning: evidence checkpoint failed: {exc}', file=sys.stderr)

    reloaded = False
    try:
        # This also validates the destination via a real atomic replacement.
        # A failed initial save must prevent every fault, including throw/die.
        checkpoint(required=True)
        try:
            for action, code in [('ok', None), ('throw', 'tool_exception'), ('die', 'tool_terminated'), ('reenter', 'reentrant_tool')]:
                checkpoint(f'probe:{action}')
                result = tool('DevCallGuardProbe', action=action)
                assert result.get('code') == code if code else result.get('success'), result
                assert tool('ControlPlugin', action='status', id='dips++-dev')['success']
                print(action, code or 'ok', flush=True)
            checkpoint('interleaving')
            with concurrent.futures.ThreadPoolExecutor() as pool:
                a = pool.submit(tool, 'DevCallGuardProbe', action='wait')
                # Confirm first admission instead of depending on a shell timing guess.
                until = time.monotonic() + 5
                while not any(c['tool'] == 'DevCallGuardProbe' for c in status()['active']):
                    if time.monotonic() > until:
                        raise RuntimeError('could not observe wait probe admission')
                b = pool.submit(tool, 'WaitUntil', condition='mode', equals='Impossible', timeoutMs=700, pollMs=20)
                assert a.result()['success']
                assert tool('DevCallGuardProbe')['success']
                assert b.result()['success']
            print('interleaved completion ok', flush=True)
            checkpoint('probe:forever')
            assert tool('DevCallGuardProbe', action='forever')['code'] == 'tool_timeout'
            quarantined = status()
            assert quarantined['recoveryRequired'] and quarantined['expiredWorkers']
            assert tool('ControlPlugin', action='status', id='dips++-dev')['code'] == 'recovery_required'
            assert request('recover', instance='wrong')['code'] == 'stale_instance'
        finally:
            # Cleanup failures must not replace the exception that brought us here.
            primary = sys.exc_info()[1]
            try:
                cleanup['state'] = 'checking_status'
                checkpoint('cleanup')
                current = status()
                if current['recoveryRequired']:
                    cleanup.update(state='requesting_reload', instance=current['instance'])
                    checkpoint()
                    assert request('recover', instance=current['instance'])['output']['reloadQueued']
                    cleanup['state'] = 'waiting_reload'
                    checkpoint()
                    until = time.monotonic() + 60
                    while time.monotonic() < until:
                        try:
                            new = status()
                            if new['instance'] != current['instance']:
                                assert not new['active'] and not new['recoveryRequired']
                                reloaded = True
                                cleanup['newInstance'] = new['instance']
                                break
                        except (OSError, ValueError):
                            pass
                        time.sleep(.1)
                    else:
                        raise RuntimeError('bridge reload not confirmed; stop live work and inspect fresh Openplanet.log')
                if reloaded:
                    for plugin in snapshot:
                        cleanup.update(state='loading', currentPlugin=plugin['id'])
                        checkpoint()
                        path = plugin['sourcePath']
                        if plugin['type'] == 'Folder':
                            path = path.rstrip('/\\') + '/'
                        result = tool('ControlPlugin', action='load', id=plugin['id'],
                                      path=path, source=plugin['source'], type=plugin['type'])
                        assert result['success'], result
                        check_compile(result['output'])
                        cleanup['state'] = 'checking_identity'
                        checkpoint()
                        observed = tool('GetPlugin', id=plugin['id'], includeSourcePath=True)
                        assert observed['success'], observed
                        if identity(observed['output']) != identity(plugin):
                            raise UnknownState(f"{plugin['id']} identity changed; retained descriptor preserved")
                        cleanup['state'] = 'restoring_enabled'
                        checkpoint()
                        result = tool('ControlPlugin', action='setEnabled', id=plugin['id'], enabled=plugin['enabled'])
                        assert result['success'], result
                        observed = tool('GetPlugin', id=plugin['id'], includeSourcePath=True)
                        assert observed['success'], observed
                        assert identity(observed['output']) == identity(plugin), observed
                        assert observed['output']['enabled'] is plugin['enabled'], observed
                        cleanup['restored'].append(plugin['id'])
                        checkpoint()
                cleanup['state'] = 'complete' if reloaded else 'reload_not_required'
                cleanup.pop('currentPlugin', None)
                checkpoint()
            except BaseException as exc:
                cleanup['failedAt'] = cleanup['state']
                cleanup.update(state='failed', error=failure(exc))
                if primary is None:
                    raise
                print(f'warning: cleanup also failed: {exc}', file=sys.stderr)
        assert reloaded
        assert tool('ControlPlugin', action='status', id='dips++-dev')['success']
        checkpoint('complete')
        print('timeout, quarantine, real reload, dependent restoration PASS', flush=True)
    except BaseException as exc:
        evidence['failure'] = {'phase': evidence['phase'], **failure(exc)}
        evidence['phase'] = 'failed'
        raise
    finally:
        # Independent of the cleanup finally: retain diagnostics even if it raises.
        checkpoint()


if __name__ == '__main__':
    main()
