namespace TmMcp {
    // ResolveMwIds: MwId values to names and names to values.
    //
    // An MwId is a u32: the top two bits are a tag (00 numeric "#N", 01 interned name,
    // 10 error, 11 unassigned; 0xFFFFFFFF is the null id). A tag-01 id is
    // 0x40000000 | (table << 16 | slot) into the game's string intern tables.
    // tm-editor-plus-plus/research/2026-08-18-MwIds.md has the layout.
    //
    // values -> names reads the intern tables first and only calls MwId.GetName() on an id
    // whose slot is occupied: GetName() on any other tag-01 value reads garbage or crashes
    // the game. names -> values looks the name up with reads only (MwIdPolicy.as ports the
    // engine's hash and probe order, checked against the live tables before it is trusted).
    // register:true instead calls MwId.SetName(), which adds a missing name to the table:
    // the only write this tool can cause, and the reason it is opt-in.

    // CMwId_ResolveCString: AND EDX,0x3FFFFFFF / LEA R8,[g_CMwId_HashTables] / index decode.
    // Same pattern as E++ Editor/Dev/MwId.as.
    const string MWID_TABLES_PATTERN = "81 E2 FF FF FF 3F 4C 8D 05 ?? ?? ?? ?? 8B C2 0F B7 CA 48 C1 E8 10";
    const uint MWID_TABLE_COUNT_OFFSET = 0x200; // static array of 32 {uint* pSlots, uint buckets, pad}
    const uint MWID_BLOB_OFFSET = 0x10;         // {char* p, uint used, uint cap} sits right before the tables
    const uint MWID_MAX_VALUES = 4096;
    const uint MWID_MAX_NAMES = 1024;
    const uint MWID_SELFTEST_PER_TABLE = 8;

    uint64 g_MwIdTablesPtr = 0;
    bool g_MwIdTablesSearched = false;
    string g_MwIdTablesError = "";
    bool g_MwIdLookupTested = false;
    uint g_MwIdLookupChecked = 0;
    array<string> g_MwIdLookupFailures;

    class MwIdLiveTables : MwIdTableReader {
        uint64 tables;
        MwIdLiveTables(uint64 tables) { this.tables = tables; }
        uint TableCount() { return Dev::ReadUInt32(tables + MWID_TABLE_COUNT_OFFSET); }
        uint BucketCount(uint table) {
            if (table >= 32) return 0;
            return Dev::ReadUInt32(tables + uint64(table) * 16 + 8);
        }
        uint SlotOffset(uint table, uint slot) {
            if (table >= TableCount() || slot >= BucketCount(table)) return MWID_NULL;
            uint64 slots = Dev::ReadUInt64(tables + uint64(table) * 16);
            if (slots == 0) return MWID_NULL;
            return Dev::ReadUInt32(slots + uint64(slot) * 4);
        }
        string NameAt(uint offset) {
            uint64 blob = Dev::ReadUInt64(tables - MWID_BLOB_OFFSET);
            if (blob == 0 || offset >= BlobUsed()) return "";
            return Dev::ReadCString(blob + offset);
        }
        uint BlobUsed() { return Dev::ReadUInt32(tables - MWID_BLOB_OFFSET + 8); }
        uint BlobCap() { return Dev::ReadUInt32(tables - MWID_BLOB_OFFSET + 12); }
    }

    // The tables, or null with g_MwIdTablesError set. The pattern is searched once per load.
    MwIdLiveTables@ MwIdTables() {
        if (!g_MwIdTablesSearched) {
            g_MwIdTablesSearched = true;
            uint64 code = Dev::FindPattern(MWID_TABLES_PATTERN);
            if (code == 0) {
                g_MwIdTablesError = "CMwId_ResolveCString pattern not found (game update?)";
            } else {
                uint64 tables = code + 13 + uint64(int64(Dev::ReadInt32(code + 9)));
                if (tables <= Dev::BaseAddress() || tables >= Dev::BaseAddressEnd()) {
                    g_MwIdTablesError = "intern tables pointer " + Text::FormatPointer(tables) + " is outside the exe";
                } else {
                    g_MwIdTablesPtr = tables;
                }
            }
        }
        if (g_MwIdTablesPtr == 0) return null;
        MwIdLiveTables@ t = MwIdLiveTables(g_MwIdTablesPtr);
        uint n = t.TableCount();
        uint buckets = t.BucketCount(0);
        if (n == 0 || n > 32 || buckets < 3 || buckets > 0x10000 || Dev::ReadUInt64(g_MwIdTablesPtr) == 0) {
            g_MwIdTablesError = "intern tables look invalid (count " + n + ", buckets " + buckets + ")";
            return null;
        }
        return t;
    }

    Json::Value MwIdTablesJson(MwIdLiveTables@ t) {
        Json::Value o = Json::Object();
        o["found"] = t !is null;
        if (t is null) { o["error"] = g_MwIdTablesError; return o; }
        o["count"] = int(t.TableCount());
        o["buckets"] = int(t.BucketCount(0));
        o["blobUsed"] = double(t.BlobUsed());
        o["blobCap"] = double(t.BlobCap());
        return o;
    }

    // Runs MwIdLookupSelfTest once per load; true when the read-only lookup can be trusted.
    bool MwIdLookupVerified(MwIdLiveTables@ t) {
        if (t is null) return false;
        if (!g_MwIdLookupTested) {
            g_MwIdLookupTested = true;
            g_MwIdLookupChecked = MwIdLookupSelfTest(t, MWID_SELFTEST_PER_TABLE, g_MwIdLookupFailures);
        }
        return g_MwIdLookupChecked > 0 && g_MwIdLookupFailures.Length == 0;
    }

    Json::Value MwIdLookupJson(MwIdLiveTables@ t) {
        Json::Value o = Json::Object();
        o["verified"] = MwIdLookupVerified(t);
        o["checked"] = int(g_MwIdLookupChecked);
        o["failed"] = int(g_MwIdLookupFailures.Length);
        if (g_MwIdLookupFailures.Length > 0) o["firstFailure"] = g_MwIdLookupFailures[0];
        return o;
    }

    // A u32 from a JSON integer (0..0xFFFFFFFF, or a negative int32: -1 is 0xFFFFFFFF)
    // or a "0x..."/decimal string.
    bool MwIdParseValue(Json::Value@ v, uint &out value) {
        if (v.GetType() == Json::Type::Number) {
            double d = double(v);
            if (d != Math::Floor(d)) return false;
            if (d >= 0 && d <= 4294967295.0) { value = uint(uint64(d)); return true; }
            if (d < 0 && d >= -2147483648.0) { value = uint(int(d)); return true; }
            return false;
        }
        uint64 parsed = 0;
        if (!TryParsePtr(v, parsed) || parsed > 0xFFFFFFFF) return false;
        value = uint(parsed);
        return true;
    }

    void MwIdAddValueFields(Json::Value &inout o, uint value) {
        o["value"] = double(value);
        o["hex"] = Text::Format("0x%08x", value);
        o["tag"] = MwIdTagName(value);
    }

    Json::Value MwIdValueJson(MwIdLiveTables@ t, uint value) {
        Json::Value o = Json::Object();
        MwIdAddValueFields(o, value);
        uint tag = value & MWID_TAG_MASK;
        if (tag == 0) {
            o["defined"] = true;
            o["name"] = MwId(value).GetName();
        } else if (tag == MWID_TAG_NAME) {
            o["table"] = int((value & MWID_PAYLOAD_MASK) >> 16);
            o["slot"] = int(value & 0xFFFF);
            if (t is null) {
                o["defined"] = Json::Value();
                o["problem"] = "intern tables not found, so the id cannot be checked; GetName() on an undefined id can crash the game";
            } else {
                string problem = MwIdInternProblem(t, value);
                o["defined"] = problem.Length == 0;
                if (problem.Length == 0) o["name"] = MwId(value).GetName();
                else o["problem"] = problem;
            }
        } else {
            o["defined"] = false;
        }
        return o;
    }

    Json::Value MwIdNameJson(MwIdLiveTables@ t, const string &in name, bool doRegister) {
        Json::Value o = Json::Object();
        o["name"] = name;
        if (MwIdIsNullSpelling(name)) {
            MwIdAddValueFields(o, MWID_NULL);
            if (doRegister) o["registered"] = false;
            return o;
        }
        if (!doRegister) {
            int index = MwIdLookupIndex(t, name);
            o["existed"] = index >= 0;
            if (index >= 0) MwIdAddValueFields(o, MWID_TAG_NAME | uint(index));
            if (index == -2) o["problem"] = "intern tables look inconsistent";
            return o;
        }
        // The blob only grows when SetName interns a new string.
        uint before = t is null ? 0 : t.BlobUsed();
        MwId id = MwId();
        id.SetName(name);
        MwIdAddValueFields(o, id.Value);
        if (t is null) {
            o["registered"] = Json::Value();
            o["existed"] = Json::Value();
        } else {
            bool added = t.BlobUsed() != before;
            o["registered"] = added;
            if ((id.Value & MWID_TAG_MASK) == MWID_TAG_NAME) o["existed"] = !added;
        }
        return o;
    }

    Json::Value@ ResolveMwIds(Json::Value &in input) {
        bool hasValues = input.HasKey("values");
        bool hasNames = input.HasKey("names");
        bool hasPtr = input.HasKey("ptr");
        if (!hasValues && !hasNames && !hasPtr) {
            return MakeError("pass values (ids to name), names (names to ids), or ptr (DEV builds)", "INVALID_INPUT");
        }
        bool doRegister = input.HasKey("register") && bool(input["register"]);
        bool internIndex = input.HasKey("internIndex") && bool(input["internIndex"]);

        array<uint> values;
        if (hasValues) {
            auto arr = input["values"];
            if (arr.GetType() != Json::Type::Array || arr.Length > MWID_MAX_VALUES) {
                return MakeError("values must be an array of at most " + MWID_MAX_VALUES + " ids", "INVALID_INPUT");
            }
            for (uint i = 0; i < arr.Length; i++) {
                uint v = 0;
                if (!MwIdParseValue(arr[i], v)) {
                    return MakeError("values[" + i + "] must be an integer 0..0xFFFFFFFF, a negative int32 (-1 is 0xFFFFFFFF) or a \"0x...\" string", "INVALID_INPUT");
                }
                if (internIndex && (v & MWID_TAG_MASK) == 0) v |= MWID_TAG_NAME;
                values.InsertLast(v);
            }
        }
        array<string> names;
        if (hasNames) {
            auto arr = input["names"];
            if (arr.GetType() != Json::Type::Array || arr.Length > MWID_MAX_NAMES) {
                return MakeError("names must be an array of at most " + MWID_MAX_NAMES + " strings", "INVALID_INPUT");
            }
            for (uint i = 0; i < arr.Length; i++) {
                if (arr[i].GetType() != Json::Type::String) return MakeError("names[" + i + "] must be a string", "INVALID_INPUT");
                names.InsertLast(string(arr[i]));
            }
        }

        auto tables = MwIdTables();
        if (hasNames && !doRegister && !MwIdLookupVerified(tables)) {
            string why = tables is null ? g_MwIdTablesError
                : "the lookup did not match the live tables (" + g_MwIdLookupFailures.Length + " of " + g_MwIdLookupChecked + " names)";
            return MakeError("cannot look names up without registering them: " + why, "MWID_LOOKUP_UNAVAILABLE", false, "",
                "register:true gets the ids from MwId.SetName, which adds any missing name to the game's id table.");
        }

        Json::Value output = Json::Object();
        output["tables"] = MwIdTablesJson(tables);
        if (hasNames) {
            if (!doRegister) output["lookup"] = MwIdLookupJson(tables);
            Json::Value rows = Json::Array();
            uint added = 0;
            for (uint i = 0; i < names.Length; i++) {
                auto row = MwIdNameJson(tables, names[i], doRegister);
                if (row.HasKey("registered") && row["registered"].GetType() == Json::Type::Boolean && bool(row["registered"])) added++;
                rows.Add(row);
            }
            output["names"] = rows;
            if (doRegister) output["registeredCount"] = int(added);
        }
        if (hasValues) {
            Json::Value rows = Json::Array();
            for (uint i = 0; i < values.Length; i++) rows.Add(MwIdValueJson(tables, values[i]));
            output["values"] = rows;
        }
        if (hasPtr) {
#if DEV
            auto err = MwIdReadAt(input, tables, output);
            if (err !is null) return err;
#else
            return MakeError("ptr reads raw memory and is only in DEV builds", "DEV_ONLY", false, "",
                "Read the u32s some other way and pass them as values.");
#endif
        }
        return MakeSuccess(output);
    }

#if DEV
    // ptr + offset/offsets: count u32 MwIds, stride bytes apart (E++ GetMwIdValue at a nod offset).
    Json::Value@ MwIdReadAt(Json::Value &in input, MwIdLiveTables@ tables, Json::Value &inout output) {
        uint64 ptr = 0;
        if (!ExtractPtr(input, "ptr", ptr)) return MakeError("ptr must be a \"0x...\" string or an integer", "INVALID_INPUT");
        uint64 addr = uint64(int64(ptr) + InputOffsetSum(input));
        int count = input.HasKey("count") ? int(input["count"]) : 1;
        int stride = input.HasKey("stride") ? int(input["stride"]) : 4;
        if (count < 1 || count > int(MWID_MAX_VALUES)) return MakeError("count must be 1.." + MWID_MAX_VALUES, "INVALID_INPUT");
        if (stride < 4 || stride > 0x10000) return MakeError("stride must be 4..65536", "INVALID_INPUT");
        Json::Value rows = Json::Array();
        for (int i = 0; i < count; i++) {
            uint64 at = addr + uint64(i) * uint64(stride);
            uint v = 0;
            try {
                v = Dev::SafeReadUInt32(at);
            } catch {
                output["readError"] = "unreadable at " + PtrToHex(at) + ": " + getExceptionInfo();
                break;
            }
            auto row = MwIdValueJson(tables, v);
            row["addr"] = PtrToHex(at);
            rows.Add(row);
        }
        output["read"] = rows;
        return null;
    }
#endif
}
