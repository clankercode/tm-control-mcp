"""The public discovery schema and dispatch registrations stay usable together."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/McpTools.as').read_text()


def schema(name):
    line = next(line for line in SOURCE.splitlines() if f'MakeTool("{name}"' in line)
    return json.loads(re.search(r", '(\{.*\})'\)\);$", line).group(1))


def test_public_tools_discovery_and_dispatch():
    for name in ['PatchLayerXml', 'ControlEditorScriptPlugins', 'DevNativeAuthProbe']:
        assert f'name == "{name}"' in SOURCE
        call = 'RunDevNativeAuthProbe' if name == 'DevNativeAuthProbe' else name
        assert f'if (name == "{name}") return {call}(input);' in SOURCE
        assert schema(name)['additionalProperties'] is False
    assert schema('PatchLayerXml')['required'] == ['layerIndex', 'find', 'replace', 'confirm']
    assert schema('DevNativeAuthProbe')['properties']['mode']['enum'] == ['status']
    assert schema('ControlEditorScriptPlugins')['properties']['action']['enum'] == ['status', 'reload']
    assert schema('ControlFids')['properties']['confirm']['type'] == 'boolean'
    assert schema('ControlFids')['properties']['replaceAll']['type'] == 'boolean'
    for name in ['setText', 'packStatus', 'mountPack', 'unmountPack']:
        assert f'if (action == "{name}") return FidsAction' in (ROOT / 'src/FidsTools.as').read_text()
    assert 'FidsPacksShutdown();' in (ROOT / 'src/Server.as').read_text()


def test_auth_probe_registration_is_dev_only():
    for token in ['if (name == "DevNativeAuthProbe") return RunDevNativeAuthProbe(input);', 'tools.Add(MakeTool("DevNativeAuthProbe"']:
        at = SOURCE.index(token)
        assert SOURCE.rfind('#if DEV', 0, at) > SOURCE.rfind('#endif', 0, at)
