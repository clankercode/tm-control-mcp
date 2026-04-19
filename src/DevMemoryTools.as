namespace TmMcp {
    // ---- Pointer parsing & formatting ----

    string PtrToHex(uint64 ptr) {
        return Text::FormatPointer(ptr);
    }

    // Accept either a JSON string ("0x...", "1234") or an integer (uint64 range).
    bool TryParsePtr(Json::Value@ v, uint64 &out ptr) {
        if (v is null) return false;
        auto t = v.GetType();
        if (t == Json::Type::Number) {
            double d = double(v);
            if (d < 0.0) return false;
            ptr = uint64(d);
            return true;
        }
        if (t == Json::Type::String) {
            string s = string(v);
            s = s.Trim();
            if (s.Length == 0) return false;
            if (s.StartsWith("0x") || s.StartsWith("0X")) {
                s = s.SubStr(2);
                uint64 acc = 0;
                for (uint i = 0; i < s.Length; i++) {
                    int c = int(s[i]);
                    int d = -1;
                    if (c >= 0x30 && c <= 0x39) d = c - 0x30;          // '0'..'9'
                    else if (c >= 0x61 && c <= 0x66) d = c - 0x61 + 10; // 'a'..'f'
                    else if (c >= 0x41 && c <= 0x46) d = c - 0x41 + 10; // 'A'..'F'
                    else return false;
                    acc = (acc << 4) | uint64(d);
                }
                ptr = acc;
                return true;
            }
            // plain decimal
            uint64 acc = 0;
            for (uint i = 0; i < s.Length; i++) {
                int c = int(s[i]);
                if (c < 0x30 || c > 0x39) return false;
                acc = acc * 10 + uint64(c - 0x30);
            }
            ptr = acc;
            return true;
        }
        return false;
    }

    bool ExtractPtr(Json::Value &in input, const string &in key, uint64 &out ptr) {
        if (!input.HasKey(key)) return false;
        return TryParsePtr(input[key], ptr);
    }

    // Add up a "offset" int and an optional "offsets" array of ints into a single delta.
    int64 InputOffsetSum(Json::Value &in input) {
        int64 total = 0;
        if (input.HasKey("offset")) {
            total += int64(int(input["offset"]));
        }
        if (input.HasKey("offsets") && input["offsets"].GetType() == Json::Type::Array) {
            auto arr = input["offsets"];
            for (uint i = 0; i < arr.Length; i++) {
                total += int64(int(arr[i]));
            }
        }
        return total;
    }

    // ---- Safe read dispatch ----

    string ByteHexPadded(uint8 b) {
        string hex = "0123456789abcdef";
        string s = "";
        s += hex.SubStr(uint(b >> 4), 1);
        s += hex.SubStr(uint(b & 0xF), 1);
        return s;
    }

    // Read len bytes starting at ptr. Returns a hex dump string plus an array of bytes.
    Json::Value SafeReadBytes(uint64 ptr, uint len) {
        Json::Value res = Json::Object();
        Json::Value arr = Json::Array();
        string hex = "";
        uint readOk = 0;
        for (uint i = 0; i < len; i++) {
            uint8 b = 0;
            bool ok = false;
            try {
                b = Dev::SafeReadUInt8(ptr + uint64(i));
                ok = true;
            } catch { }
            if (!ok) {
                res["truncatedAt"] = int(i);
                break;
            }
            arr.Add(int(b));
            if (i > 0 && (i % 16) == 0) hex += " ";
            else if (i > 0 && (i % 4) == 0) hex += " ";
            hex += ByteHexPadded(b);
            readOk++;
        }
        res["bytes"] = arr;
        res["hex"] = hex;
        res["readBytes"] = int(readOk);
        return res;
    }

    // Probes a pointer. Returns readable=true only if we could read a single byte.
    Json::Value ProbePointer(uint64 ptr) {
        Json::Value p = Json::Object();
        p["ptr"] = PtrToHex(ptr);
        if (ptr == 0) {
            p["readable"] = false;
            p["reason"] = "null";
            return p;
        }
        try {
            uint8 b = Dev::SafeReadUInt8(ptr);
            p["readable"] = true;
            p["firstByte"] = int(b);
        } catch {
            p["readable"] = false;
            p["reason"] = getExceptionInfo();
        }
        return p;
    }

    // kind = u8|u16|u32|u64|i8|i16|i32|i64|f32|vec2|vec3|vec4|cstr|bytes
    Json::Value@ RunDevSafeRead(Json::Value &in input) {
        uint64 ptr = 0;
        if (!ExtractPtr(input, "ptr", ptr)) return MakeError("missing or malformed 'ptr'");
        int64 delta = InputOffsetSum(input);
        uint64 addr = uint64(int64(ptr) + delta);

        string kind = input.HasKey("kind") ? string(input["kind"]) : "u64";
        kind = kind.ToLower();

        Json::Value output = Json::Object();
        output["ptr"] = PtrToHex(ptr);
        output["offsetSum"] = int(delta);
        output["addr"] = PtrToHex(addr);
        output["kind"] = kind;

        if (addr == 0) {
            output["error"] = "resolved address is null";
            return MakeSuccess(output);
        }

        // Quick probe for readability so we give useful feedback even if the typed read below errors.
        output["probe"] = ProbePointer(addr);
        if (!bool(output["probe"]["readable"])) {
            output["error"] = "address not readable";
            return MakeSuccess(output);
        }

        string readErr = "";
        try {
            if (kind == "u8") {
                output["value"] = int(Dev::SafeReadUInt8(addr));
            } else if (kind == "u16") {
                output["value"] = int(Dev::SafeReadUInt16(addr));
            } else if (kind == "u32") {
                uint32 v = Dev::SafeReadUInt32(addr);
                output["value"] = int(v);
                output["hex"] = "0x" + Text::Format("%x", v);
            } else if (kind == "u64") {
                uint64 v = Dev::SafeReadUInt64(addr);
                output["value"] = PtrToHex(v);
                output["decimal"] = double(v);
            } else if (kind == "i8") {
                output["value"] = int(Dev::SafeReadInt8(addr));
            } else if (kind == "i16") {
                output["value"] = int(Dev::SafeReadInt16(addr));
            } else if (kind == "i32") {
                output["value"] = int(Dev::SafeReadInt32(addr));
            } else if (kind == "i64") {
                output["value"] = double(Dev::SafeReadInt64(addr));
            } else if (kind == "f32" || kind == "float") {
                output["value"] = double(Dev::SafeReadFloat(addr));
            } else if (kind == "vec2") {
                output["value"] = Vec2ToJson(Dev::SafeReadVec2(addr));
            } else if (kind == "vec3") {
                output["value"] = Vec3ToJson(Dev::SafeReadVec3(addr));
            } else if (kind == "vec4") {
                auto v = Dev::SafeReadVec4(addr);
                Json::Value a = Json::Array();
                a.Add(v.x); a.Add(v.y); a.Add(v.z); a.Add(v.w);
                output["value"] = a;
            } else if (kind == "cstr" || kind == "cstring") {
                uint maxLen = input.HasKey("len") ? uint(int(input["len"])) : 256;
                // Read byte-by-byte safely, terminating on null.
                string s = "";
                uint readCount = 0;
                bool terminated = false;
                for (uint i = 0; i < maxLen; i++) {
                    uint8 b = 0;
                    try {
                        b = Dev::SafeReadUInt8(addr + uint64(i));
                    } catch {
                        output["truncatedAt"] = int(i);
                        break;
                    }
                    readCount++;
                    if (b == 0) { terminated = true; break; }
                    s += Text::Format("%c", b);
                }
                output["value"] = s;
                output["readBytes"] = int(readCount);
                output["terminated"] = terminated;
            } else if (kind == "bytes" || kind == "hex") {
                uint len = input.HasKey("len") ? uint(int(input["len"])) : 64;
                if (len > 4096) len = 4096;
                output["dump"] = SafeReadBytes(addr, len);
            } else {
                output["error"] = "unknown kind: " + kind;
            }
        } catch {
            readErr = getExceptionInfo();
        }
        if (readErr.Length > 0) output["readError"] = readErr;

        return MakeSuccess(output);
    }

    // ---- Pointer discovery ----

    Json::Value NodInfo(CMwNod@ nod, const string &in label) {
        Json::Value o = Json::Object();
        o["label"] = label;
        if (nod is null) {
            o["ptr"] = PtrToHex(0);
            o["isNull"] = true;
            return o;
        }
        uint64 ptr = Editor::GetNodPointer(nod);
        o["ptr"] = PtrToHex(ptr);
        o["isNull"] = false;
        // Peek vtable & refcount - a healthy CMwNod has a readable vtable at +0 and refcount at +0x8.
        Json::Value peek = Json::Object();
        try {
            peek["vtable"] = PtrToHex(Dev::SafeReadUInt64(ptr));
        } catch {
            peek["vtableError"] = getExceptionInfo();
        }
        try {
            peek["refCount"] = int(Dev::SafeReadUInt32(ptr + 0x8));
        } catch {
            peek["refCountError"] = getExceptionInfo();
        }
        o["peek"] = peek;
        return o;
    }

    Json::Value@ RunDevGetPointers(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null) return MakeError("editor not available");

        Json::Value output = Json::Object();
        output["base"] = PtrToHex(Dev::BaseAddress());

        Json::Value nods = Json::Array();
        nods.Add(NodInfo(editor, "editor"));
        nods.Add(NodInfo(editor.PluginMapType, "pluginMapType"));
        nods.Add(NodInfo(editor.Challenge, "challenge"));
        if (editor.Cursor !is null) nods.Add(NodInfo(editor.Cursor, "cursor"));

        auto app = cast<CTrackMania>(GetApp());
        if (app !is null) nods.Add(NodInfo(app, "app"));

        output["nods"] = nods;

        bool listAO = input.HasKey("listAnchoredObjects") ? bool(input["listAnchoredObjects"]) : false;
        int aoLimit = input.HasKey("anchoredObjectsLimit") ? int(input["anchoredObjectsLimit"]) : 20;
        if (listAO && editor.Challenge !is null) {
            Json::Value arr = Json::Array();
            auto anchored = editor.Challenge.AnchoredObjects;
            uint take = Math::Min(uint(aoLimit), anchored.Length);
            for (uint i = 0; i < take; i++) {
                arr.Add(NodInfo(anchored[i], "anchoredObjects[" + i + "]"));
            }
            output["anchoredObjectsCount"] = int(anchored.Length);
            output["anchoredObjects"] = arr;
        }

        bool listBlocks = input.HasKey("listBlocks") ? bool(input["listBlocks"]) : false;
        int blockLimit = input.HasKey("blocksLimit") ? int(input["blocksLimit"]) : 20;
        if (listBlocks && editor.Challenge !is null) {
            Json::Value arr = Json::Array();
            auto blocks = editor.Challenge.Blocks;
            uint take = Math::Min(uint(blockLimit), blocks.Length);
            for (uint i = 0; i < take; i++) {
                arr.Add(NodInfo(blocks[i], "blocks[" + i + "]"));
            }
            output["blocksCount"] = int(blocks.Length);
            output["blocks"] = arr;
        }

        // pmt.Items is the source of healthy CGameCtnEditorScriptAnchoredObject wrappers.
        // Exposing pointers here lets us memory-compare against MacroblockInstanceItemsResults wrappers.
        bool listPmtItems = input.HasKey("listPmtItems") ? bool(input["listPmtItems"]) : false;
        int pmtItemsLimit = input.HasKey("pmtItemsLimit") ? int(input["pmtItemsLimit"]) : 20;
        if (listPmtItems && editor.PluginMapType !is null) {
            auto pmt = editor.PluginMapType;
            Json::Value arr = Json::Array();
            uint total = pmt.Items.Length;
            uint take = Math::Min(uint(pmtItemsLimit), total);
            for (uint i = 0; i < take; i++) {
                arr.Add(NodInfo(pmt.Items[i], "pmt.Items[" + i + "]"));
            }
            output["pmtItemsCount"] = int(total);
            output["pmtItems"] = arr;
        }

        return MakeSuccess(output);
    }

    // ---- Compute items pointers (no field access) ----

    // Variant of RunComputeItemsDiagnostic that avoids touching wrapper fields. Only reports raw pointers.
    Json::Value@ RunDevComputeItemsPointers(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null || editor.Challenge is null) {
            return MakeError("editor not available");
        }
        auto pmt = editor.PluginMapType;

        if (!input.HasKey("mbPath")) return MakeError("missing mbPath");
        string mbPath = string(input["mbPath"]);
        if (mbPath.Length == 0) return MakeError("mbPath is empty");

        int x = input.HasKey("x") ? int(input["x"]) : 0;
        int y = input.HasKey("y") ? int(input["y"]) : 0;
        int z = input.HasKey("z") ? int(input["z"]) : 0;
        string dirStr = input.HasKey("dir") ? string(input["dir"]) : "North";
        auto dir = DirFromString(dirStr);
        auto color = CGameEditorPluginMap::EMapElemColor::Default;
        bool force = input.HasKey("force") ? bool(input["force"]) : false;

        auto model = pmt.GetMacroblockModelFromFilePath(mbPath);
        if (model is null) return MakeError("macroblock model not found: " + mbPath);

        Json::Value output = Json::Object();
        output["mbPath"] = mbPath;
        output["modelPtr"] = PtrToHex(Editor::GetNodPointer(model));

        CGameEditorMapMacroBlockInstance@ inst;
        string instError = "";
        try {
            @inst = pmt.CreateMacroblockInstance(model, nat3(uint(x), uint(y), uint(z)), dir, color, force);
        } catch {
            instError = getExceptionInfo();
        }
        if (inst is null) {
            output["error"] = instError.Length > 0 ? instError : "CreateMacroblockInstance returned null";
            return MakeSuccess(output);
        }
        output["instancePtr"] = PtrToHex(Editor::GetNodPointer(inst));

        string computeError = "";
        try {
            pmt.ComputeItemsForMacroblockInstance(inst);
        } catch {
            computeError = getExceptionInfo();
        }
        if (computeError.Length > 0) {
            output["computeError"] = computeError;
            return MakeSuccess(output);
        }

        uint nbItems = pmt.MacroblockInstanceItemsResults.Length;
        output["nbComputedItems"] = int(nbItems);

        Json::Value arr = Json::Array();
        for (uint i = 0; i < nbItems; i++) {
            auto w = pmt.MacroblockInstanceItemsResults[i];
            Json::Value entry = Json::Object();
            entry["index"] = int(i);
            if (w is null) {
                entry["isNull"] = true;
                arr.Add(entry);
                continue;
            }
            uint64 wptr = Editor::GetNodPointer(w);
            entry["ptr"] = PtrToHex(wptr);
            entry["probe"] = ProbePointer(wptr);
            // Peek vtable + refcount so we can compare wrapper layouts without field accesses.
            if (wptr != 0) {
                try { entry["vtable"] = PtrToHex(Dev::SafeReadUInt64(wptr)); } catch { entry["vtableError"] = getExceptionInfo(); }
                try { entry["refCount"] = int(Dev::SafeReadUInt32(wptr + 0x8)); } catch { entry["refCountError"] = getExceptionInfo(); }
            }
            arr.Add(entry);
        }
        output["items"] = arr;
        return MakeSuccess(output);
    }
}
