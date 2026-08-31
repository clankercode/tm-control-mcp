"""Source contract + input validation for SetMoodTimeOfDay / ComputeShadows.

No live game required. Registration is three separate edits in McpTools.as
(the sync-dispatch allowlist, the dispatch branch, and the MakeTool entry).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
sys.path.insert(0, str(ROOT / "tools"))

import call as call_mod  # noqa: E402

QUALITY_NAMES = ("NotComputed", "VeryFast", "Fast", "Default", "High", "Ultra")
QUALITY_INDEX = {name.lower(): i for i, name in enumerate(QUALITY_NAMES)}
QUALITY_INDEX["vfast"] = 1


def _mcp_tools() -> str:
    return (SRC / "McpTools.as").read_text()


def _impl() -> str:
    return (SRC / "MapEnvironment.as").read_text()


def _schema(name: str) -> dict:
    line = next(l for l in _mcp_tools().splitlines() if f'MakeTool("{name}"' in l)
    match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
    assert match, f"could not extract schema from MakeTool({name})"
    schema = json.loads(match.group(1))
    assert isinstance(schema, dict)
    return schema


def parse_shadows_quality(value=None):
    """Python port of MapEnvironment.as ParseShadowsQuality (default Default)."""
    if value is None:
        return 3, "Default", ""
    if isinstance(value, bool):
        return None, None, "quality must be a string or int"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        n = int(value)
        if n < 0 or n > 5:
            return None, None, "quality int must be 0..5"
        return n, QUALITY_NAMES[n], ""
    if not isinstance(value, str):
        return None, None, "quality must be a string or int"
    raw = value
    s = raw.lower().replace("_", "").replace("-", "").replace(" ", "")
    if not s:
        return None, None, "quality is empty"
    if s.isdigit():
        n = int(s)
        if n < 0 or n > 5:
            return None, None, "unknown quality"
        return n, QUALITY_NAMES[n], ""
    if s not in QUALITY_INDEX:
        return None, None, "unknown quality: " + raw
    n = QUALITY_INDEX[s]
    return n, QUALITY_NAMES[n], ""


def test_tools_registered_at_all_three_points():
    text = _mcp_tools()
    for name in ("SetMoodTimeOfDay", "ComputeShadows"):
        assert f'name == "{name}"' in text, f"{name} missing from allowlist"
        assert f'if (name == "{name}") return {name}(input);' in text, \
            f"{name} missing dispatch branch"
        assert f'MakeTool("{name}"' in text, f"{name} missing MakeTool"


def test_tools_are_not_dev_only():
    text = _mcp_tools()
    for name in ("SetMoodTimeOfDay", "ComputeShadows"):
        idx = text.index(f'name == "{name}"')
        dev_block = text.find("#if DEV")
        while dev_block >= 0:
            dev_end = text.find("#endif", dev_block)
            assert not (dev_block < idx < dev_end), f"{name} must not be DEV-only"
            dev_block = text.find("#if DEV", dev_end if dev_end >= 0 else dev_block + 1)


def test_setmood_schema_requires_time_of_day():
    schema = _schema("SetMoodTimeOfDay")
    assert schema["required"] == ["timeOfDay01"]
    assert "timeOfDay01" in schema["properties"]
    assert "dynamic" in schema["properties"]
    assert call_mod.validate_input("SetMoodTimeOfDay", {}, schema) == \
        "missing required parameter 'timeOfDay01'"
    assert call_mod.validate_input("SetMoodTimeOfDay", {"timeOfDay01": 0.25}, schema) == ""
    err = call_mod.validate_input("SetMoodTimeOfDay", {"foo": 1}, schema)
    assert "unknown parameter" in err


def test_impl_rejects_missing_time_of_day():
    text = _impl()
    assert 'if (!input.HasKey("timeOfDay01"))' in text
    assert "missing timeOfDay01" in text
    assert 'return MakeError("missing timeOfDay01", "INVALID_INPUT"' in text
    assert "MoodTimeOfDay01 = tod" in text
    assert "MoodIsDynamicTime" in text


def test_compute_shadows_schema_quality_is_optional_union():
    schema = _schema("ComputeShadows")
    assert "required" not in schema
    quality = schema["properties"]["quality"]
    assert quality["type"] == ["string", "integer"]
    assert schema["properties"]["bustCache"]["type"] == "boolean"
    assert call_mod.validate_input("ComputeShadows", {}, schema) == ""
    assert call_mod.validate_input("ComputeShadows", {"quality": "High"}, schema) == ""
    assert call_mod.validate_input("ComputeShadows", {"quality": 4}, schema) == ""
    assert call_mod.validate_input("ComputeShadows", {"bustCache": False}, schema) == ""


def test_parse_shadows_quality_default_and_names():
    n, name, err = parse_shadows_quality(None)
    assert err == ""
    assert n == 3
    assert name == "Default"
    for i, expected in enumerate(QUALITY_NAMES):
        n, name, err = parse_shadows_quality(i)
        assert err == ""
        assert n == i
        assert name == expected
        n, name, err = parse_shadows_quality(expected)
        assert err == ""
        assert n == i
        n, name, err = parse_shadows_quality(expected.lower())
        assert err == ""
        assert n == i
    n, name, err = parse_shadows_quality("very-fast")
    assert err == ""
    assert n == 1
    n, name, err = parse_shadows_quality("vfast")
    assert err == ""
    assert n == 1


def test_parse_shadows_quality_rejects_bad_input():
    _, _, err = parse_shadows_quality("Nope")
    assert "unknown quality" in err
    _, _, err = parse_shadows_quality(9)
    assert "0..5" in err
    _, _, err = parse_shadows_quality(-1)
    assert "0..5" in err
    _, _, err = parse_shadows_quality("")
    assert "empty" in err


def test_impl_parse_shadows_quality_matches_enum():
    text = _impl()
    assert "bool ParseShadowsQuality(" in text
    for name in QUALITY_NAMES:
        assert f"EShadowsQuality::{name}" in text, name
    assert "EShadowsQuality::High" in text
    assert "EShadowsQuality::Default" in text
    assert text.count("EShadowsQuality::Default") >= 2
    assert "unknown quality:" in text
    assert "quality int must be 0..5" in text
    assert "bustCache" in text
    assert 'Reflection::GetType("CHmsLightMapCache")' in text
    assert 'GetMember("m_Quality")' in text
    assert 'Fids::GetGameFolder("GameData/LightMap/HmsPackLightMap")' in text
    assert "ComputeShadows1(quality)" in text
    assert 'output["lightmapCompute"] = LightmapComputeSnapshot()' in text
    assert 'output["started"] = true' in text
