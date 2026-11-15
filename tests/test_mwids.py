"""ResolveMwIds: pure helpers in stock AngelScript, plus source contracts.

The engine side (finding the intern tables, MwId.GetName/SetName) needs the game.
Here the hash and the read-only lookup run against intern tables built in Python by
the same insert loop as the engine's CMwId_InternString32 (Ghidra decompile, see
src/MwIdPolicy.as), with tiny bucket counts so names spill across several tables.
"""
import json
import re
from pathlib import Path
import subprocess

from test_pack_updates import as_runner  # noqa: F401  (pytest fixture)

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "src" / "MwIdPolicy.as"
TOOL = (ROOT / "src" / "MwIds.as").read_text()
CODE = re.sub(r"//[^\n]*", "", TOOL)  # comments mention SetName/GetName too
MCP_TOOLS = (ROOT / "src" / "McpTools.as").read_text()

M = 0x5BD1E995
SEED = 0x57489862
MASK = 0xFFFFFFFF


def murmur2(data: bytes, seed=SEED) -> int:
    """Hash_Murmur2 @ 0x1401262f0: MurmurHash2, but 0 for an empty input."""
    n = len(data)
    if n == 0:
        return 0
    h = (seed ^ n) & MASK
    i = 0
    while n - i >= 4:
        k = int.from_bytes(data[i:i + 4], "little")
        k = (k * M) & MASK
        k ^= k >> 24
        k = (k * M) & MASK
        h = ((h * M) & MASK) ^ k
        i += 4
    rest = n - i
    if rest == 3:
        h ^= data[i + 2] << 16
    if rest >= 2:
        h ^= data[i + 1] << 8
    if rest >= 1:
        h ^= data[i]
        h = (h * M) & MASK
    h ^= h >> 13
    h = (h * M) & MASK
    h ^= h >> 15
    return h


class InternTables:
    """CMwId_InternString32 with lookupOnly=0, as decompiled."""

    def __init__(self, buckets, seed=SEED):
        self.buckets = buckets
        self.seed = seed
        self.tables = [[MASK] * buckets]
        self.blob = b""

    def name_at(self, off):
        return self.blob[off:self.blob.index(b"\0", off)]

    def intern(self, name: str) -> int:
        data = name.encode()
        n = self.buckets
        h = murmur2(data, self.seed)
        slot, step = h % n, h % (n - 2) + 1
        t = 0
        while True:
            if t >= len(self.tables):
                self.tables.append([MASK] * n)
            for _ in range(5):
                off = self.tables[t][slot]
                if off == MASK:
                    self.tables[t][slot] = len(self.blob)
                    self.blob += data + b"\0"
                    return (t << 16) | slot
                if self.name_at(off) == data:
                    return (t << 16) | slot
                slot = (slot + step) % n
            t += 1

    def as_fixture(self, var="tables"):
        offsets = sorted({o for tab in self.tables for o in tab if o != MASK})
        rows = ", ".join("{" + ", ".join(f"0x{o:x}" for o in tab) + "}" for tab in self.tables)
        offs = ", ".join(f"0x{o:x}" for o in offsets)
        names = ", ".join(as_literal(self.name_at(o).decode()) for o in offsets)
        return (f"FakeTables {var};\n"
                f"    {var}.slots = {{{rows}}};\n"
                f"    {var}.offsets = {{{offs}}};\n"
                f"    {var}.names = {{{names}}};\n")


def as_literal(s: str) -> str:
    out = ""
    for ch in s:
        if ch in '"\\':
            out += "\\" + ch
        elif ord(ch) < 0x20 or ord(ch) > 0x7E:
            out += f"\\u{ord(ch):04x}"
        else:
            out += ch
    return '"' + out + '"'


FAKE_TABLES = r'''
class FakeTables : TmMcp::MwIdTableReader {
    array<array<uint>> slots;
    array<uint> offsets;
    array<string> names;
    uint TableCount() { return slots.Length; }
    uint BucketCount(uint t) { return t < slots.Length ? slots[t].Length : 0; }
    uint SlotOffset(uint t, uint s) { return t < slots.Length && s < slots[t].Length ? slots[t][s] : 0xFFFFFFFF; }
    string NameAt(uint offset) { int i = offsets.Find(offset); return i < 0 ? "" : names[uint(i)]; }
}
'''


def run_policy(runner, tmp_path, body):
    case = tmp_path / "mwid_case.as"
    case.write_text(FAKE_TABLES + "void RunTests() {\n    using namespace TmMcp;\n" + body + "\n}\n")
    result = subprocess.run([str(runner), str(POLICY), str(case)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


NAMES = [f"Name{i}" for i in range(40)] + ["CarSport", "CarSnow", "CharacterPilot", "Nadeo", "Vehicles",
                                            "a", "ab", "abc", "abcd", "abcde", "café", "水", "Stadium"]


def test_hash_matches_engine_murmur2(as_runner, tmp_path):
    words = ["", "a", "ab", "abc", "abcd", "abcde", "abcdefgh", "abcdefghi", "CarSport", "café", "水水"]
    checks = "".join(f'    Check(MwIdHash({as_literal(w)}) == 0x{murmur2(w.encode()):08x}, {as_literal("hash " + w)});\n'
                     for w in words)
    run_policy(as_runner, tmp_path, checks)


def test_tags_and_null_spellings(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    Check(MwIdTagName(0) == "number", "0 is #0");
    Check(MwIdTagName(256) == "number", "#256");
    Check(MwIdTagName(0x40000000) == "name", "tag 01");
    Check(MwIdTagName(0x4002ffff) == "name", "tag 01 index");
    Check(MwIdTagName(0x80000000) == "error", "tag 10");
    Check(MwIdTagName(0xC0000000) == "unassigned", "bare tag 11");
    Check(MwIdTagName(0xFFFFFFFF) == "unassigned", "null id");
    Check(MwIdIsNullSpelling(""), "empty");
    Check(MwIdIsNullSpelling("Unassigned"), "Unassigned");
    Check(MwIdIsNullSpelling("NullId"), "NullId");
    Check(!MwIdIsNullSpelling("unassigned"), "case matters");
    Check(!MwIdIsNullSpelling("#0"), "#0 is not null");
    ''')


def test_lookup_finds_every_interned_name_across_tables(as_runner, tmp_path):
    tables = InternTables(11)
    expected = {name: tables.intern(name) for name in NAMES}
    assert len(tables.tables) >= 4, "fixture must spill into several tables"
    assert {v >> 16 for v in expected.values()} >= {0, 1, 2}
    body = "    " + tables.as_fixture()
    for name, index in expected.items():
        body += f'    Check(MwIdLookupIndex(tables, {as_literal(name)}) == {index}, {as_literal("lookup " + name)});\n'
    for missing in ["Name40", "carsport", "CarSport ", "abcdef", "caf"]:
        body += f'    Check(MwIdLookupIndex(tables, {as_literal(missing)}) == -1, {as_literal("miss " + missing)});\n'
    body += r'''
    Check(MwIdLookupIndex(tables, "") == -1, "empty is the null id");
    Check(MwIdLookupIndex(tables, "Unassigned") == -1, "Unassigned is the null id");
    '''
    run_policy(as_runner, tmp_path, body)


def test_lookup_refuses_inconsistent_tables(as_runner, tmp_path):
    run_policy(as_runner, tmp_path, r'''
    FakeTables none;
    Check(MwIdLookupIndex(none, "x") == -2, "no tables");
    FakeTables uneven;
    uneven.slots = {{0, 0, 0, 0, 0}, {0xFFFFFFFF}};
    uneven.offsets = {0};
    uneven.names = {"other"};
    Check(MwIdLookupIndex(uneven, "x") == -2, "tables of different sizes");
    FakeTables tiny;
    tiny.slots = {{0xFFFFFFFF, 0xFFFFFFFF}};
    Check(MwIdLookupIndex(tiny, "x") == -2, "fewer than 3 buckets");
    ''')


def test_intern_problem_only_passes_occupied_slots(as_runner, tmp_path):
    tables = InternTables(11)
    car = tables.intern("CarSport")
    empty = next(s for s in range(11) if tables.tables[0][s] == MASK)
    body = "    " + tables.as_fixture() + f'''
    Check(MwIdInternProblem(tables, 0x40000000 | {car}) == "", "occupied slot");
    Check(MwIdInternProblem(tables, 0x40000000 | {empty}) == "intern slot is empty", "empty slot");
    Check(MwIdInternProblem(tables, 0x40000000 | (1 << 16)).IndexOf("not allocated") >= 0, "table past the count");
    Check(MwIdInternProblem(tables, 0x40000000 | (0x3FFF << 16)).IndexOf("not allocated") >= 0, "huge table index");
    Check(MwIdInternProblem(tables, 0x40000000 | 11).IndexOf("past table 0") >= 0, "slot past the buckets");
    Check(MwIdInternProblem(tables, {car}) == "not an interned-name id", "tag 00 is not interned");
    Check(MwIdInternProblem(tables, 0xFFFFFFFF) == "not an interned-name id", "null id");
    '''
    run_policy(as_runner, tmp_path, body)


def test_self_test_passes_on_engine_tables_and_catches_a_wrong_hash(as_runner, tmp_path):
    tables = InternTables(11)
    for name in NAMES:
        tables.intern(name)
    per_table = 3
    expect = sum(min(per_table, sum(1 for o in tab if o != MASK)) for tab in tables.tables)
    # Tables built by a different hash: what a wrong port of the engine's hash looks like.
    other = InternTables(101, seed=SEED ^ 1)
    for name in NAMES[:30]:
        other.intern(name)
    body = "    " + tables.as_fixture() + "    " + other.as_fixture("other") + f'''
    array<string> failures;
    uint checked = MwIdLookupSelfTest(tables, {per_table}, failures);
    Check(checked == {expect}, "checked " + checked);
    Check(failures.Length == 0, "engine-built tables pass");
    array<string> otherFailures;
    Check(MwIdLookupSelfTest(other, 8, otherFailures) == 8, "8 names checked");
    Check(otherFailures.Length > 0, "a layout the hash does not produce fails");
    ''' + r'''
    FakeTables empty;
    empty.slots = {{0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF}};
    array<string> none;
    Check(MwIdLookupSelfTest(empty, 8, none) == 0, "nothing to check is not a pass");
    '''
    run_policy(as_runner, tmp_path, body)


def test_registered_at_all_three_points():
    assert 'name == "ResolveMwIds"' in MCP_TOOLS, "missing from IsToolName"
    assert 'if (name == "ResolveMwIds") return ResolveMwIds(input);' in MCP_TOOLS, "missing dispatch"
    assert 'MakeTool("ResolveMwIds"' in MCP_TOOLS, "missing MakeTool registration"
    allow = MCP_TOOLS.index('name == "ResolveMwIds"')
    dev = MCP_TOOLS.rfind("#if DEV", 0, allow)
    assert dev < 0 or MCP_TOOLS.find("#endif", dev) < allow, "ResolveMwIds must ship in release builds"


def test_schema():
    line = next(l for l in MCP_TOOLS.splitlines() if 'MakeTool("ResolveMwIds"' in l)
    match = re.search(r"'(\{\"type\":.*\})'\)\);?\s*$", line)
    assert match, "could not extract schema"
    schema = json.loads(match.group(1))
    props = schema["properties"]
    assert props["values"]["type"] == "array"
    assert props["names"]["type"] == "array"
    assert props["register"]["type"] == "boolean"
    assert props["internIndex"]["type"] == "boolean"
    assert props["ptr"]["type"] == ["string", "integer"]
    assert schema.get("additionalProperties") is False
    assert "required" not in schema
    # The description states the side effect of register.
    assert "register:true" in line and "ADDS a missing name" in line


def test_only_register_writes_and_ptr_is_dev_only():
    assert "Dev::Write" not in CODE and "Dev::SetOffset" not in CODE and "Dev::Patch" not in CODE
    # SetName (the interning write) appears once, after the register branch point.
    assert CODE.count(".SetName(") == 1
    body = CODE[CODE.index("Json::Value MwIdNameJson("):]
    assert body.index("if (!doRegister)") < body.index(".SetName(")
    # Raw pointer reads are DEV-only, like DevSafeRead.
    read_at = TOOL.index("Json::Value@ MwIdReadAt(")
    assert TOOL.rfind("#if DEV", 0, read_at) > TOOL.rfind("#endif", 0, read_at)
    assert '"DEV_ONLY"' in TOOL


def test_get_name_only_after_the_intern_check():
    body = CODE[CODE.index("Json::Value MwIdValueJson("):CODE.index("Json::Value MwIdNameJson(")]
    tagged = body[body.index("tag == MWID_TAG_NAME"):]
    assert tagged.index("MwIdInternProblem(") < tagged.index(".GetName()")
