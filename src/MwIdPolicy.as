namespace TmMcp {
    // Pure MwId helpers: no game types, so tests/test_mwids.py runs them in stock
    // AngelScript. The game side (table discovery, reads, the tool) is MwIds.as.
    // Layout and algorithm: tm-editor-plus-plus/research/2026-08-18-MwIds.md, and the
    // Ghidra decompile of CMwId_InternString32 / CMwId_HashString32 / Hash_Murmur2.

    const uint MWID_TAG_MASK = 0xC0000000;
    const uint MWID_TAG_NAME = 0x40000000;
    const uint MWID_PAYLOAD_MASK = 0x3FFFFFFF;
    const uint MWID_NULL = 0xFFFFFFFF;
    const uint MWID_HASH_SEED = 0x57489862;
    const uint MWID_MURMUR_M = 0x5bd1e995;
    const uint MWID_PROBES_PER_TABLE = 5;

    // Top two bits: 00 numeric "#N", 01 interned name, 10 "Internal Error", 11 unassigned.
    string MwIdTagName(uint value) {
        uint tag = value & MWID_TAG_MASK;
        if (tag == 0) return "number";
        if (tag == MWID_TAG_NAME) return "name";
        if (tag == 0x80000000) return "error";
        return "unassigned";
    }

    // The engine stores 0xFFFFFFFF for these and never interns them.
    bool MwIdIsNullSpelling(const string &in name) {
        return name.Length == 0 || name == "Unassigned" || name == "NullId";
    }

    // Hash_Murmur2 as the engine has it: MurmurHash2 with the intern seed, and 0 for
    // an empty string. Bytes are the UTF-8 bytes of the name.
    uint MwIdHash(const string &in name) {
        uint len = name.Length;
        if (len == 0) return 0;
        uint h = MWID_HASH_SEED ^ len;
        uint i = 0;
        while (len - i >= 4) {
            uint k = uint(name[i]) | (uint(name[i + 1]) << 8) | (uint(name[i + 2]) << 16) | (uint(name[i + 3]) << 24);
            k *= MWID_MURMUR_M;
            k ^= k >> 24;
            k *= MWID_MURMUR_M;
            h *= MWID_MURMUR_M;
            h ^= k;
            i += 4;
        }
        uint rest = len - i;
        if (rest == 3) h ^= uint(name[i + 2]) << 16;
        if (rest >= 2) h ^= uint(name[i + 1]) << 8;
        if (rest >= 1) {
            h ^= uint(name[i]);
            h *= MWID_MURMUR_M;
        }
        h ^= h >> 13;
        h *= MWID_MURMUR_M;
        h ^= h >> 15;
        return h;
    }

    // Read access to the intern tables, so the lookup below runs against the live game
    // (MwIds.as) or against arrays in the tests.
    interface MwIdTableReader {
        uint TableCount();
        uint BucketCount(uint table);
        // Blob offset of the name in that slot; 0xFFFFFFFF when the slot is empty.
        uint SlotOffset(uint table, uint slot);
        // The NUL-terminated name at that blob offset.
        string NameAt(uint offset);
    }

    // CMwId_InternString32 with lookupOnly=1, using only reads: bucket and step come from
    // table 0's bucket count; each table is probed 5 times, and the probe position carries
    // on into the next table. The first empty slot is a miss. Returns the intern index
    // (table << 16 | slot; OR in 0x40000000 for the id), -1 if the name is not interned,
    // -2 if the tables look inconsistent.
    int MwIdLookupIndex(MwIdTableReader@ tables, const string &in name) {
        if (MwIdIsNullSpelling(name)) return -1;
        uint nTables = tables.TableCount();
        if (nTables == 0 || nTables > 32) return -2;
        uint nBuckets = tables.BucketCount(0);
        if (nBuckets < 3 || nBuckets > 0x10000) return -2;
        uint hash = MwIdHash(name);
        uint slot = hash % nBuckets;
        uint step = hash % (nBuckets - 2) + 1;
        for (uint t = 0; t < nTables; t++) {
            if (tables.BucketCount(t) != nBuckets) return -2;
            for (uint p = 0; p < MWID_PROBES_PER_TABLE; p++) {
                uint offset = tables.SlotOffset(t, slot);
                if (offset == MWID_NULL) return -1;
                if (tables.NameAt(offset) == name) return int((t << 16) | slot);
                slot = (slot + step) % nBuckets;
            }
        }
        return -1;
    }

    // "" when a tag-01 value names an occupied intern slot; otherwise why it does not.
    // GetName() on a tag-01 value that fails this reads past the tables or the string
    // blob and can crash the game, so only names that pass are ever stringified.
    string MwIdInternProblem(MwIdTableReader@ tables, uint value) {
        if ((value & MWID_TAG_MASK) != MWID_TAG_NAME) return "not an interned-name id";
        uint table = (value & MWID_PAYLOAD_MASK) >> 16;
        uint slot = value & 0xFFFF;
        uint nTables = tables.TableCount();
        if (table >= nTables) return "intern table " + table + " is not allocated (" + nTables + " tables)";
        if (slot >= tables.BucketCount(table)) return "slot " + slot + " is past table " + table + "'s " + tables.BucketCount(table) + " buckets";
        if (tables.SlotOffset(table, slot) == MWID_NULL) return "intern slot is empty";
        return "";
    }

    // Checks MwIdLookupIndex against names already in the tables: the first `perTable`
    // occupied slots of each table must look up to their own slot. A wrong hash or probe
    // order fails here, so the lookup is only trusted on a build where this passes.
    // Returns how many names were checked; failures lists the ones that did not match.
    uint MwIdLookupSelfTest(MwIdTableReader@ tables, uint perTable, array<string> &inout failures) {
        uint checked = 0;
        uint nTables = tables.TableCount();
        if (nTables > 32) nTables = 32;
        for (uint t = 0; t < nTables; t++) {
            uint nBuckets = tables.BucketCount(t);
            uint found = 0;
            for (uint s = 0; s < nBuckets && found < perTable; s++) {
                uint offset = tables.SlotOffset(t, s);
                if (offset == MWID_NULL) continue;
                string name = tables.NameAt(offset);
                if (MwIdIsNullSpelling(name)) continue;
                found++;
                checked++;
                int got = MwIdLookupIndex(tables, name);
                if (got != int((t << 16) | s)) failures.InsertLast(name + " @" + t + ":" + s + " -> " + got);
            }
        }
        return checked;
    }
}
