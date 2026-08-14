"""Editor++ is optional: Editor:: calls must sit behind #if DEPENDENCY_EDITOR."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src"


def unguarded_editor_calls(path: Path) -> list[str]:
    depth = 0
    hits = []
    for i, line in enumerate(path.read_text().splitlines(), 1):
        s = line.strip()
        if s.startswith("#if"):
            if "DEPENDENCY_EDITOR" in s or depth:
                depth += 1
        elif s.startswith("#endif") and depth:
            depth -= 1
        if "Editor::" not in line or depth:
            continue
        if s.startswith("//"):
            continue
        if '"Editor::' in line or "'Editor::" in line:
            continue
        if "call Editor::" in line or "through Editor::" in line or "exposes Editor::" in line:
            continue
        # prose / concatenation mentioning the API
        if s.startswith("+") and "Editor::" in s:
            continue
        hits.append(f"{path.name}:{i}: {s}")
    return hits


def test_no_unguarded_editor_calls():
    hits = []
    for path in sorted(ROOT.glob("*.as")):
        hits.extend(unguarded_editor_calls(path))
    assert hits == [], "unguarded Editor:: calls:\n" + "\n".join(hits)


def test_info_toml_editor_is_optional():
    text = (ROOT.parent / "info.toml").read_text()
    assert "optional_dependencies" in text
    assert "Editor" in text
    # not a hard dep
    for line in text.splitlines():
        if line.strip().startswith("dependencies"):
            assert "Editor" not in line
