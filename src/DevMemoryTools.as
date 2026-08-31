namespace TmMcp {
    // ---- Pointer parsing & formatting ----

    string PtrToHex(uint64 ptr) {
        return Text::FormatPointer(ptr);
    }

    uint64 NodPointerOrZero(CMwNod@ nod) {
        return FidsPointerOfNod(nod);
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
        uint64 ptr = NodPointerOrZero(nod);
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

    // ---- CopyPaste selection driver (raw engine CGameEditorPluginMap API) ----

    // Region-select map content and copy it into editor.CopyPasteMacroBlockInfo,
    // same primitives the vanilla copy-paste tool UI uses.
    Json::Value@ RunCopyPasteSelection(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available");
        auto pmt = editor.PluginMapType;

        if (input.HasKey("reset") ? bool(input["reset"]) : true) {
            pmt.CopyPaste_ResetSelection();
        }

        bool copied = false;
        if (input.HasKey("lo") && input.HasKey("hi")) {
            auto lo = input["lo"];
            auto hi = input["hi"];
            if (lo.GetType() != Json::Type::Array || lo.Length != 3
                || hi.GetType() != Json::Type::Array || hi.Length != 3) {
                return MakeError("lo/hi must be [x,y,z] block-unit arrays");
            }
            int3 nlo = int3(int(lo[0]), int(lo[1]), int(lo[2]));
            int3 nhi = int3(int(hi[0]), int(hi[1]), int(hi[2]));
            pmt.CopyPaste_AddOrSubSelection(nlo, nhi);
            if (input.HasKey("doCopy") ? bool(input["doCopy"]) : true) {
                pmt.CopyPaste_Copy();
                copied = true;
            }
        }

        Json::Value output = Json::Object();
        output["reset"] = input.HasKey("reset") ? bool(input["reset"]) : true;
        output["copied"] = copied;
        output["copyPasteMbInfo"] = NodInfo(editor.CopyPasteMacroBlockInfo, "copyPasteMacroBlockInfo");
        return MakeSuccess(output);
    }

    // ---- Input bindings (profile) dump ----

    // Live walk: GetApp().PlayerProfiles / CurrentProfile -> CGamePlayerProfile ->
    // InputBindingsConfigs -> chunk.Config (CInputBindingsConfig) + raw u64 dump.
    Json::Value@ RunDevInputBindings(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return MakeError("app not available");

        Json::Value output = Json::Object();
        auto profiles = app.PlayerProfiles;
        output["playerProfilesCount"] = int(profiles.Length);

        Json::Value arr = Json::Array();
        for (uint i = 0; i < profiles.Length; i++) {
            auto p = profiles[i];
            Json::Value po = Json::Object();
            po["ptr"] = PtrToHex(NodPointerOrZero(p));
            po["name"] = p.ProfileName;
            auto ib = p.InputBindingsConfigs;
            po["inputBindingsConfigsCount"] = int(ib.Length);
            Json::Value chunks = Json::Array();
            for (uint j = 0; j < ib.Length; j++) {
                auto chunk = ib[j];
                Json::Value co = Json::Object();
                co["ptr"] = PtrToHex(NodPointerOrZero(chunk));
                auto cfg = chunk.Config;
                co["configPtr"] = PtrToHex(NodPointerOrZero(cfg));
                if (cfg !is null) {
                    Json::Value raw = Json::Array();
                    for (uint off = 0; off < 144; off += 8)
                        raw.Add(PtrToHex(Dev::GetOffsetUint64(cfg, off)));
                    co["raw64"] = raw;
                }
                chunks.Add(co);
            }
            po["chunks"] = chunks;
            arr.Add(po);
        }
        output["profiles"] = arr;

        auto cp = app.CurrentProfile;
        if (cp !is null) {
            Json::Value cpo = Json::Object();
            cpo["ptr"] = PtrToHex(NodPointerOrZero(cp));
            cpo["profileOld"] = PtrToHex(NodPointerOrZero(cp.ProfileOld));
            cpo["profileNew"] = PtrToHex(NodPointerOrZero(cp.ProfileNew));
            if (cp.ProfileOld !is null) {
                auto ib = cp.ProfileOld.InputBindingsConfigs;
                cpo["profileOldInputBindingsConfigsCount"] = int(ib.Length);
                Json::Value chunks = Json::Array();
                for (uint j = 0; j < ib.Length; j++) {
                    auto cfg = ib[j].Config;
                    Json::Value co = Json::Object();
                    co["configPtr"] = PtrToHex(NodPointerOrZero(cfg));
                    if (cfg !is null) {
                        Json::Value raw = Json::Array();
                        for (uint off = 0; off < 144; off += 8)
                            raw.Add(PtrToHex(Dev::GetOffsetUint64(cfg, off)));
                        co["raw64"] = raw;
                    }
                    chunks.Add(co);
                }
                cpo["chunks"] = chunks;
            }
            output["currentProfile"] = cpo;
        }

        // ManiaPlanetScriptAPI binding-list buffers (populated by InputBindings_UpdateList,
        // which the controls settings page drives)
        auto mp = cast<CGameManiaPlanet>(GetApp());
        if (mp !is null && mp.ManiaPlanetScriptAPI !is null) {
            auto api = mp.ManiaPlanetScriptAPI;
            Json::Value ao = Json::Object();
            ao["ptr"] = PtrToHex(NodPointerOrZero(api));
            ao["actionNamesCount"] = int(api.InputBindings_ActionNames.Length);
            ao["bindingsCount"] = int(api.InputBindings_Bindings.Length);
            ao["bindingsRawCount"] = int(api.InputBindings_BindingsRaw.Length);
            ao["playerInputsCount"] = int(api.InputBindings_PlayerInputsCount);
            int take = input.HasKey("maxEntries") ? int(input["maxEntries"]) : 24;
            Json::Value names = Json::Array();
            for (uint i = 0; i < api.InputBindings_ActionNames.Length && int(i) < take; i++)
                names.Add(string(api.InputBindings_ActionNames[i]));
            ao["actionNames"] = names;
            Json::Value binds = Json::Array();
            for (uint i = 0; i < api.InputBindings_Bindings.Length && int(i) < take; i++)
                binds.Add(string(api.InputBindings_Bindings[i]));
            ao["bindings"] = binds;
            Json::Value rawB = Json::Array();
            for (uint i = 0; i < api.InputBindings_BindingsRaw.Length && int(i) < take; i++)
                rawB.Add(api.InputBindings_BindingsRaw[i]);
            ao["bindingsRaw"] = rawB;
            output["maniaPlanetScriptAPI"] = ao;
        }

        // raw head of the opaque new-profile object (full 776 bytes when full=true)
        if (cp !is null && cp.ProfileNew !is null) {
            uint len = input.HasKey("full") && bool(input["full"]) ? 776 : 256;
            Json::Value raw = Json::Array();
            for (uint off = 0; off < len; off += 8)
                raw.Add(PtrToHex(Dev::GetOffsetUint64(cp.ProfileNew, off)));
            output["profileNewRaw64"] = raw;
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
        output["modelPtr"] = PtrToHex(NodPointerOrZero(model));

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
        output["instancePtr"] = PtrToHex(NodPointerOrZero(inst));

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
            uint64 wptr = NodPointerOrZero(w);
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

    Json::Value NamedTypeOffset(const Reflection::MwClassInfo@ ty, const string &in memberName) {
        Json::Value row = Json::Object();
        row["name"] = memberName;
        if (ty is null) {
            row["found"] = false;
            return row;
        }
        auto mem = ty.GetMember(memberName);
        if (mem is null) {
            row["found"] = false;
            return row;
        }
        row["found"] = true;
        row["offset"] = int(mem.Offset);
        return row;
    }

    Json::Value FastArraySlot(CGameCtnChallenge@ map, uint16 off, int rel, uint scriptAoLen) {
        Json::Value slot = Json::Object();
        slot["rel"] = rel;
        slot["offset"] = int(off);
        if (rel == 0) slot["claimed"] = "AnchoredObjects";
        else if (rel == 0x20) slot["claimed"] = "O_MAP_MACROBLOCK_INFOS";
        uint64 ptr = Dev::GetOffsetUint64(map, off);
        uint len = Dev::GetOffsetUint32(map, off + 0x8);
        uint cap = Dev::GetOffsetUint32(map, off + 0xC);
        slot["ptr"] = PtrToHex(ptr);
        slot["len"] = int(len);
        slot["cap"] = int(cap);
        slot["ptrProbe"] = ProbePointer(ptr);
        if (rel == 0) {
            slot["scriptAnchoredLength"] = int(scriptAoLen);
            slot["lenMatchesScript"] = len == scriptAoLen;
        }
        bool plausible = ptr != 0 && len > 0 && len < 10000 && cap >= len;
        slot["plausibleFastArray"] = plausible;
        if (plausible && bool(slot["ptrProbe"]["readable"])) {
            Json::Value els = Json::Array();
            uint take = Math::Min(len, 8);
            for (uint i = 0; i < take; i++) {
                Json::Value el = Json::Object();
                try {
                    el["instId"] = Dev::SafeReadInt32(ptr + i * 8);
                    el["mwId"] = int(Dev::SafeReadUInt32(ptr + i * 8 + 4));
                } catch {
                    el["error"] = getExceptionInfo();
                }
                els.Add(el);
            }
            slot["firstEntries"] = els;
        }
        return slot;
    }

    Json::Value@ RunDevInspectChallengeOffsets(Json::Value &in input) {
        auto editor = GetEditor();
        if (editor is null || editor.Challenge is null) return MakeError("editor not available");
        auto map = editor.Challenge;
        auto ty = Reflection::GetType("CGameCtnChallenge");
        if (ty is null) return MakeError("no CGameCtnChallenge reflection");

        Json::Value named = Json::Object();
        const string[] names = {
            "Blocks", "BakedBlocks", "AnchoredObjects",
            "ChallengeParameters", "Size", "ScriptMetadata", "ClipAmbiance"
        };
        uint16 ao = 0;
        uint16 cp = 0;
        for (uint i = 0; i < names.Length; i++) {
            Json::Value row = NamedTypeOffset(ty, names[i]);
            named[names[i]] = row;
            if (bool(row["found"])) {
                if (names[i] == "AnchoredObjects") ao = uint16(int(row["offset"]));
                if (names[i] == "ChallengeParameters") cp = uint16(int(row["offset"]));
            }
        }

        Json::Value between = Json::Array();
        for (uint i = 0; i < ty.Members.Length; i++) {
            auto mem = ty.Members[i];
            if (ao == 0) break;
            if (mem.Offset < ao) continue;
            if (cp != 0 && mem.Offset > cp) continue;
            Json::Value row = Json::Object();
            row["name"] = mem.Name;
            row["offset"] = int(mem.Offset);
            between.Add(row);
        }

        uint scriptAoLen = map.AnchoredObjects.Length;
        Json::Value slots = Json::Array();
        Json::Value words = Json::Object();
        if (ao != 0) {
            int startRel = -0x20;
            int endRel = 0x80;
            for (int rel = startRel; rel <= endRel; rel += 8) {
                uint16 off = uint16(int(ao) + rel);
                slots.Add(FastArraySlot(map, off, rel, scriptAoLen));
                words[Text::Format("0x%03x", int(off))] = Text::Format("0x%08x", Dev::GetOffsetUint32(map, off));
            }
        }

        Json::Value output = Json::Object();
        output["namedOffsets"] = named;
        output["expectedMacroblockInfos"] = int(ao) + 0x20;
        output["commentedHistorical"] = 0x2c8;
        output["gapAoToParams"] = int(cp) - int(ao);
        output["membersFromAoToParams"] = between;
        output["fastArraysFromAo"] = slots;
        output["u32FromAoWindow"] = words;
        output["scriptAnchoredObjects"] = int(scriptAoLen);
        output["scriptBlocks"] = int(map.Blocks.Length);
        if (editor.PluginMapType !is null) {
            output["pmtMacroblockInstances"] = int(editor.PluginMapType.MacroblockInstances.Length);
        }

        Json::Value found = Json::Array();
        for (uint off = 0x200; off <= 0x500; off += 8) {
            uint64 ptr = Dev::GetOffsetUint64(map, off);
            uint len = Dev::GetOffsetUint32(map, off + 0x8);
            uint cap = Dev::GetOffsetUint32(map, off + 0xC);
            bool plausible = ptr != 0 && len > 0 && len < 10000 && cap >= len;
            bool emptyAlloc = ptr != 0 && len == 0 && cap > 0 && cap < 10000;
            if (!plausible && !emptyAlloc) continue;
            Json::Value row = Json::Object();
            row["offset"] = int(off);
            row["ptr"] = PtrToHex(ptr);
            row["len"] = int(len);
            row["cap"] = int(cap);
            row["kind"] = plausible ? "populated" : "emptyAlloc";
            row["ptrReadable"] = bool(ProbePointer(ptr)["readable"]);
            if (plausible && bool(row["ptrReadable"]) && len <= 32) {
                Json::Value els = Json::Array();
                uint take = Math::Min(len, 4);
                for (uint i = 0; i < take; i++) {
                    Json::Value el = Json::Object();
                    try {
                        el["i32_0"] = Dev::SafeReadInt32(ptr + i * 8);
                        el["u32_4"] = int(Dev::SafeReadUInt32(ptr + i * 8 + 4));
                    } catch {
                        el["error"] = getExceptionInfo();
                    }
                    els.Add(el);
                }
                row["first8"] = els;
            }
            found.Add(row);
        }
        output["plausibleFastArrays_0x200_0x500"] = found;
        return MakeSuccess(output);
    }

    // ---- Scene components (any mode; editor not required) ----

    string SafePtrHex(uint64 addr) {
        try { return PtrToHex(Dev::SafeReadUInt64(addr)); } catch { return "ERR"; }
    }

    int SafeI32(uint64 addr) {
        try { return Dev::SafeReadInt32(addr); } catch { return -2147483647; }
    }

    Json::Value RawWindow(uint64 addr, uint len) {
        Json::Value w = SafeReadBytes(addr, len);
        w["addr"] = PtrToHex(addr);
        return w;
    }

    Json::Value DynaPeek(uint64 dyna) {
        Json::Value d = Json::Object();
        d["ptr"] = PtrToHex(dyna);
        d["mesh_0x20"] = SafePtrHex(dyna + 0x20);
        d["dynaShape_0x30"] = SafePtrHex(dyna + 0x30);
        d["gmSurf_0x38"] = SafePtrHex(dyna + 0x38);
        d["locAnimIsPhysical_0x40"] = SafeI32(dyna + 0x40);
        uint64 mesh = 0;
        try { mesh = Dev::SafeReadUInt64(dyna + 0x20); } catch {}
        if (mesh != 0) {
            d["meshVisualsPtr_0x168"] = SafePtrHex(mesh + 0x168);
            d["meshVisualsLen_0x170"] = SafeI32(mesh + 0x170);
        }
        return d;
    }

    // NSceneDestructiblePhy layout from Ghidra (2026-08-27): slot Dyna* table +0x38/+0x40,
    // per-slot HMS +0x58, slot u32 ids +0x88/+0x90, dyna bodies +0x110/+0x118,
    // dynamize/break queue +0x178/+0x180 (stride 0x30), locked +0x618.
    Json::Value DestructiblePhyDump(uint64 c, uint maxSlots) {
        Json::Value o = Json::Object();
        o["nodrefTable_0x38"] = SafePtrHex(c + 0x38);
        o["slotCount_0x40"] = SafeI32(c + 0x40);
        o["word_0x48"] = SafeI32(c + 0x48);
        o["perSlotHms_0x58"] = SafePtrHex(c + 0x58);
        o["ids_0x88"] = SafePtrHex(c + 0x88);
        o["idsCount_0x90"] = SafeI32(c + 0x90);
        o["bodies_0x110"] = SafePtrHex(c + 0x110);
        o["bodiesCount_0x118"] = SafeI32(c + 0x118);
        o["queue_0x178"] = SafePtrHex(c + 0x178);
        o["queueCount_0x180"] = SafeI32(c + 0x180);
        o["locked_0x618"] = SafeI32(c + 0x618);

        uint count = 0;
        try { count = Dev::SafeReadUInt32(c + 0x40); } catch {}
        if (count > 256) count = 0;
        uint64 tbl = 0;
        try { tbl = Dev::SafeReadUInt64(c + 0x38); } catch {}
        if (tbl != 0 && count > 0) {
            Json::Value dynas = Json::Array();
            uint take = Math::Min(count, maxSlots);
            for (uint i = 0; i < take; i++) {
                uint64 dyna = 0;
                try { dyna = Dev::SafeReadUInt64(tbl + uint64(i) * 8); } catch {}
                if (dyna == 0) {
                    Json::Value n = Json::Object();
                    n["ptr"] = "null";
                    dynas.Add(n);
                } else {
                    dynas.Add(DynaPeek(dyna));
                }
            }
            o["dynas"] = dynas;
        }

        uint qn = 0;
        try { qn = Dev::SafeReadUInt32(c + 0x180); } catch {}
        if (qn > 64) qn = 0;
        uint64 q = 0;
        try { q = Dev::SafeReadUInt64(c + 0x178); } catch {}
        if (q != 0 && qn > 0) {
            Json::Value qs = Json::Array();
            for (uint i = 0; i < qn; i++) {
                Json::Value e = Json::Object();
                e["b0"] = SafeI32(q + uint64(i) * 0x30);
                e["b1"] = SafeI32(q + uint64(i) * 0x30 + 1);
                qs.Add(e);
            }
            o["queueEntries"] = qs;
        }

        o["raw_0x30_0xB0"] = RawWindow(c + 0x30, 0x80);
        return o;
    }

    // NSceneDestructibleVis: render-inst bookkeeping (inst array +0x380, counts +0x388/+0x38c).
    Json::Value DestructibleVisDump(uint64 c) {
        Json::Value o = Json::Object();
        o["word_0x2d0"] = SafeI32(c + 0x2d0);
        o["arr_0x380"] = SafePtrHex(c + 0x380);
        o["count_0x388"] = SafeI32(c + 0x388);
        o["word_0x38c"] = SafeI32(c + 0x38c);
        o["raw_0x2c0_0x3a0"] = RawWindow(c + 0x2c0, 0xe0);
        return o;
    }

    // NSceneItem_SMgr records: stride 0x138, iso int3 @+0x00, cursor/preview flags u32 @+0x68.
    Json::Value SceneItemMgrDump(uint64 c, uint maxRecs) {
        Json::Value o = Json::Object();
        o["recs_0x38"] = SafePtrHex(c + 0x38);
        o["recsCount_0x40"] = SafeI32(c + 0x40);
        uint64 recs = 0;
        uint count = 0;
        try {
            recs = Dev::SafeReadUInt64(c + 0x38);
            count = Dev::SafeReadUInt32(c + 0x40);
        } catch {}
        if (recs != 0 && count > 0 && count < 4096) {
            Json::Value arr = Json::Array();
            uint take = Math::Min(count, maxRecs);
            for (uint i = 0; i < take; i++) {
                uint64 r = recs + uint64(i) * 0x138;
                Json::Value e = Json::Object();
                Json::Value iso = Json::Array();
                iso.Add(SafeI32(r));
                iso.Add(SafeI32(r + 4));
                iso.Add(SafeI32(r + 8));
                e["iso"] = iso;
                e["flags_0x68"] = SafeI32(r + 0x68);
                arr.Add(e);
            }
            o["records"] = arr;
        }
        return o;
    }

    // Walks ISceneVis's scene-manager list (via the HackScene member offset) and dumps
    // components; DestructiblePhy/Vis and SceneItem SMgrs get layout-aware field dumps.
    Json::Value@ RunDevSceneComponents(Json::Value &in input) {
        Json::Value output = Json::Object();
        output["base"] = PtrToHex(Dev::BaseAddress());

        auto scene = GetApp().GameScene;
        if (scene is null) return MakeError("GameScene is null");

        auto sceneTy = Reflection::GetType("ISceneVis");
        if (sceneTy is null) return MakeError("ISceneVis type not found");
        auto mem = sceneTy.GetMember("HackScene");
        if (mem is null) return MakeError("ISceneVis.HackScene member not found");
        uint16 listOff = uint16(int(mem.Offset) - 0x18);
        output["mgrListOff"] = int(listOff);

        CMwNod@ mgrs;
        uint count = 0;
        try {
            @mgrs = Dev::GetOffsetNod(scene, listOff);
            count = Dev::GetOffsetUint32(scene, listOff + 0x8);
        } catch {
            return MakeError("failed reading mgr list: " + getExceptionInfo());
        }
        if (mgrs is null) return MakeError("scene mgr list is null");
        output["mgrList"] = NodInfo(mgrs, "mgrList");
        output["mgrCount"] = int(count);

        // Per-scene component mgr (NGameApp scene mgr) lives at scene+0xd10; its +0x79c array
        // marks wanted component slots (u32 per slot, written by NGameApp_GameSceneCreate).
        CMwNod@ sceneMgr;
        try { @sceneMgr = Dev::GetOffsetNod(scene, 0xd10); } catch {}
        if (sceneMgr !is null) {
            output["sceneMgr"] = NodInfo(sceneMgr, "sceneMgr");
            Json::Value flags = Json::Array();
            for (uint s = 0; s < 64; s++) {
                try { flags.Add(int(Dev::GetOffsetUint32(sceneMgr, 0x79c + int(s) * 4))); }
                catch { flags.Add(-1); }
            }
            output["wantedFlags_0x79c"] = flags;
            Json::Value slots = Json::Array();
            for (uint s = 0; s < 64; s++) {
                uint64 p = 0;
                try { p = Dev::GetOffsetUint64(scene, 0x10 + int(s) * 8); } catch {}
                slots.Add(PtrToHex(p));
            }
            output["slotArray_0x10"] = slots;
        }

        // Class descriptor table (DAT_141faad30): stride 0x68 per class slot, +0 = factory fn.
        // Lets us identify which class owns each slot and check DestructiblePhy/Vis presence.
        uint64 descTable = 0;
        try { descTable = Dev::SafeReadUInt64(Dev::BaseAddress() + 0x1faad30); } catch {}
        if (descTable != 0) {
            output["descTable"] = PtrToHex(descTable);
            Json::Value probes = ProbePointer(descTable);
            output["descTableProbe"] = probes;
            if (bool(probes["readable"])) {
                Json::Value factories = Json::Array();
                for (uint s = 0; s < 64; s++) {
                    try { factories.Add(PtrToHex(Dev::SafeReadUInt64(descTable + uint64(s) * 0x68))); }
                    catch { factories.Add("ERR"); }
                }
                output["descFactories"] = factories;
            }
        }
        // Vftable of each nonempty slotArray component (+ first vtable entries) for class matching.
        if (sceneMgr !is null) {
            Json::Value vt = Json::Array();
            for (uint s = 0; s < 64; s++) {
                uint64 comp = 0;
                try { comp = Dev::GetOffsetUint64(scene, 0x10 + int(s) * 8); } catch {}
                if (comp == 0) continue;
                Json::Value e = Json::Object();
                e["slot"] = int(s);
                e["comp"] = PtrToHex(comp);
                try {
                    uint64 vfp = Dev::SafeReadUInt64(comp);
                    e["vftable"] = PtrToHex(vfp);
                    Json::Value entries = Json::Array();
                    for (uint k = 0; k < 8; k++) {
                        try { entries.Add(PtrToHex(Dev::SafeReadUInt64(vfp + uint64(k) * 8))); }
                        catch { break; }
                    }
                    e["vtEntries"] = entries;
                } catch { e["err"] = getExceptionInfo(); }
                vt.Add(e);
            }
            output["slotVftables"] = vt;
        }

        uint maxSlots = input.HasKey("maxSlots") ? uint(int(input["maxSlots"])) : 32;
        if (maxSlots > 128) maxSlots = 128;

        Json::Value comps = Json::Array();
        uint n = Math::Min(count, uint(128));
        for (uint i = 0; i < n; i++) {
            uint typeId = 0;
            uint64 ptr = 0;
            try {
                typeId = Dev::GetOffsetUint32(mgrs, int(i) * 0x18);
                ptr = Dev::GetOffsetUint64(mgrs, int(i) * 0x18 + 8);
            } catch { continue; }
            string name = "";
            try {
                auto ty = Reflection::GetType(typeId);
                if (ty !is null) name = ty.Name;
            } catch {}
            Json::Value e = Json::Object();
            e["i"] = int(i);
            e["typeId"] = Text::Format("0x%08x", typeId);
            e["name"] = name;
            e["ptr"] = PtrToHex(ptr);
            if (ptr != 0) e["probe"] = ProbePointer(ptr);
            if (ptr != 0 && name.IndexOf("Destructible") >= 0) {
                if (name.IndexOf("Phy") >= 0) e["phy"] = DestructiblePhyDump(ptr, maxSlots);
                else if (name.IndexOf("Vis") >= 0) e["vis"] = DestructibleVisDump(ptr);
            } else if (ptr != 0 && (name.IndexOf("SceneItem") >= 0 || name.IndexOf("GameItem") >= 0)) {
                e["items"] = SceneItemMgrDump(ptr, maxSlots);
            }
            comps.Add(e);
        }
        output["components"] = comps;
        return MakeSuccess(output);
    }

}
