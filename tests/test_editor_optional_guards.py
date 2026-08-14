"""E++ extraction: no Editor dependency; Editor:: must not appear in compiled src."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src"


def test_no_editor_dependency():
    toml = (ROOT.parent / "info.toml").read_text()
    deps_line = next(
        (l for l in toml.splitlines() if l.strip().startswith("optional_dependencies")),
        "",
    )
    assert "Editor" not in deps_line


def test_no_editor_ns_calls():
    offenders = []
    for p in sorted(ROOT.glob("*.as")):
        for i, line in enumerate(p.read_text().splitlines(), 1):
            s = line.strip()
            if s.startswith("//"):
                continue
            if "Editor::" in line:
                if p.name == "Guides.as":
                    continue  # prose/doc strings
                offenders.append(f"{p.name}:{i}: {s[:100]}")
    assert offenders == [], "Editor:: remains in src:\n" + "\n".join(offenders)


def test_moved_stub_surface():
    t = (ROOT / "EditorOptional.as").read_text()
    for name in [
        "PlaceBlockViaEditorPlusPlus", "PlaceItemViaEditorPlusPlus",
        "PlaceNamedMacroblock", "ControlEditMode", "ControlItemEditor",
        "SetAgentTag", "RemoveByTag", "BrowseInventoryTree",
    ]:
        assert name in t, name
    assert "moved_to_pack" in t
    assert "tm-mcp-pack-epp" in t
