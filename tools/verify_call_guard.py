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
from pathlib import Path
import time

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
        response = send_request(args.host, args.port, 70, payload)
        exchanges.append({'request': payload, 'response': response})
        if not response.get('ok'):
            raise RuntimeError(response)
        return response['data']

    def tool(name: str, **data) -> dict:
        return request('call', tool=name, input=data)['result']

    def status() -> dict:
        return request('status')['calls']

    original = status()
    if original['recoveryRequired'] or original['active']:
        raise RuntimeError('start with an idle healthy bridge; inspect status before recovery')
    snapshot = dependent_order(tool('ListPlugins', includeSourcePath=True)['output']['plugins'])
    reloaded = False
    try:
        for action, code in [('ok', None), ('throw', 'tool_exception'), ('die', 'tool_terminated'), ('reenter', 'reentrant_tool')]:
            result = tool('DevCallGuardProbe', action=action)
            assert result.get('code') == code if code else result.get('success'), result
            assert tool('ControlPlugin', action='status', id='dips++-dev')['success']
            print(action, code or 'ok', flush=True)
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
        assert tool('DevCallGuardProbe', action='forever')['code'] == 'tool_timeout'
        quarantined = status()
        assert quarantined['recoveryRequired'] and quarantined['expiredWorkers']
        assert tool('ControlPlugin', action='status', id='dips++-dev')['code'] == 'recovery_required'
        assert request('recover', instance='wrong')['code'] == 'stale_instance'
    finally:
        # Once the deliberate worker can exist, make an actual reload mandatory.
        current = status()
        if current['recoveryRequired']:
            assert request('recover', instance=current['instance'])['output']['reloadQueued']
            until = time.monotonic() + 60
            while time.monotonic() < until:
                try:
                    new = status()
                    if new['instance'] != current['instance']:
                        assert not new['active'] and not new['recoveryRequired']
                        reloaded = True
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('bridge reload not confirmed; stop live work and inspect fresh Openplanet.log')
        if reloaded:
            for plugin in snapshot:
                result = tool('ControlPlugin', action='load', id=plugin['id'])
                assert result['success'], result
                # Placeholder modules can report loaded while a required
                # dependency is absent. Preserve/report that state as a failure.
                observed = tool('ControlPlugin', action='status', id=plugin['id'])
                assert observed['success'], observed
                assert observed['output']['enabled'] == plugin['enabled'], observed
        args.evidence.write_text(json.dumps({'snapshot': snapshot, 'exchanges': exchanges}, indent=2))
    assert reloaded
    assert tool('ControlPlugin', action='status', id='dips++-dev')['success']
    print('timeout, quarantine, real reload, dependent restoration PASS', flush=True)


if __name__ == '__main__':
    main()
