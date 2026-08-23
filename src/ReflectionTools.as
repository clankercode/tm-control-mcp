namespace TmMcp {
    // Live Openplanet Reflection::MwClassInfo / MwMemberInfo dump.
    // MwMemberInfo has no member type name — only Name, NameDescriptive, Offset, ID.

    const uint16 TYPEINFO_INVALID_OFFSET = 0xFFFF;
    const int TYPEINFO_MEMBER_CAP = 10000;

    string TypeInfoHex32(uint v) {
        return Text::Format("0x%08x", v);
    }

    string TypeInfoHex16(uint16 v) {
        return Text::Format("0x%04x", int(v));
    }

    Json::Value TypeInfoClassBrief(const Reflection::MwClassInfo@ ty) {
        Json::Value o = Json::Object();
        if (ty is null) {
            o["name"] = "";
            return o;
        }
        o["name"] = string(ty.Name);
        o["id"] = int(ty.ID);
        o["idHex"] = TypeInfoHex32(ty.ID);
        o["size"] = int(ty.Size);
        return o;
    }

    Json::Value TypeInfoMemberJson(const Reflection::MwMemberInfo@ mem, const string &in declaredOn) {
        Json::Value o = Json::Object();
        o["name"] = string(mem.Name);
        string desc = string(mem.NameDescriptive);
        if (desc.Length > 0 && desc != string(mem.Name)) o["nameDescriptive"] = desc;
        o["id"] = int(mem.ID);
        o["offset"] = int(mem.Offset);
        o["offsetHex"] = TypeInfoHex16(mem.Offset);
        o["isField"] = mem.Offset != TYPEINFO_INVALID_OFFSET;
        o["declaredOn"] = declaredOn;
        return o;
    }

    bool TypeInfoMemberMatches(const Reflection::MwMemberInfo@ mem, const string &in queryLower) {
        if (queryLower.Length == 0) return true;
        if (string(mem.Name).ToLower().Contains(queryLower)) return true;
        string desc = string(mem.NameDescriptive);
        return desc.Length > 0 && desc.ToLower().Contains(queryLower);
    }

    const Reflection::MwMemberInfo@ TypeInfoOwnMember(const Reflection::MwClassInfo@ ty, const string &in name) {
        if (ty is null) return null;
        auto members = ty.Members;
        if (members is null) return null;
        for (uint i = 0; i < members.Length; i++) {
            if (members[i] is null) continue;
            if (string(members[i].Name) == name) return members[i];
        }
        return null;
    }

    int TypeInfoAppendClassMembers(
        const Reflection::MwClassInfo@ ty,
        Json::Value@ membersOut,
        const string &in queryLower,
        int limit,
        bool includeBases
    ) {
        if (ty is null) return 0;
        int matched = 0;
        if (includeBases && ty.BaseType !is null) {
            matched += TypeInfoAppendClassMembers(ty.BaseType, membersOut, queryLower, limit, true);
        }
        auto members = ty.Members;
        if (members is null) return matched;
        string declaredOn = string(ty.Name);
        for (uint i = 0; i < members.Length; i++) {
            if (members[i] is null) continue;
            if (!TypeInfoMemberMatches(members[i], queryLower)) continue;
            matched++;
            if (limit > 0 && membersOut.Length >= uint(limit)) continue;
            if (int(membersOut.Length) >= TYPEINFO_MEMBER_CAP) continue;
            membersOut.Add(TypeInfoMemberJson(members[i], declaredOn));
        }
        return matched;
    }

    Json::Value TypeInfoClassJson(const Reflection::MwClassInfo@ ty) {
        Json::Value o = TypeInfoClassBrief(ty);
        string description = string(ty.Description);
        if (description.Length > 0) o["description"] = description;
        string userName = string(ty.UserName);
        if (userName.Length > 0) o["userName"] = userName;
        string ext = string(ty.FileExtension);
        if (ext.Length > 0) o["fileExtension"] = ext;
        if (ty.BaseType !is null) {
            o["base"] = string(ty.BaseType.Name);
        } else {
            o["base"] = "";
        }
        Json::Value bases = Json::Array();
        const Reflection::MwClassInfo@ cur = ty.BaseType;
        while (cur !is null) {
            bases.Add(TypeInfoClassBrief(cur));
            @cur = cur.BaseType;
        }
        o["bases"] = bases;
        return o;
    }

    CMwNod@ TypeInfoResolveFrom(const string &in from, string &out errCode, string &out err) {
        string f = from.ToLower();
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) {
            errCode = "NO_APP";
            err = "app not available";
            return null;
        }
        if (f == "app") return app;
        if (f == "editor") {
            if (app.Editor is null) {
                errCode = "FROM_UNAVAILABLE";
                err = "no editor";
                return null;
            }
            return app.Editor;
        }
        if (f == "challenge" || f == "map" || f == "rootmap") {
            if (app.RootMap is null) {
                errCode = "FROM_UNAVAILABLE";
                err = "no RootMap";
                return null;
            }
            return app.RootMap;
        }
        if (f == "cursor") {
            auto ed = GetEditor();
            if (ed is null || ed.Cursor is null) {
                errCode = "FROM_UNAVAILABLE";
                err = "no editor cursor";
                return null;
            }
            return ed.Cursor;
        }
        if (f == "pluginmap" || f == "pmt") {
            auto ed = GetEditor();
            if (ed is null || ed.PluginMapType is null) {
                errCode = "FROM_UNAVAILABLE";
                err = "no PluginMapType";
                return null;
            }
            return ed.PluginMapType;
        }
        errCode = "BAD_FROM";
        err = "unknown from '" + from + "' (expected app|editor|challenge|cursor|pluginMap)";
        return null;
    }

    Json::Value@ GetTypeInfo(Json::Value &in input) {
        const Reflection::MwClassInfo@ ty = null;
        string lookedUpBy = "";

        if (input.HasKey("className")) {
            string className = string(input["className"]).Trim();
            if (className.Length > 0) {
                @ty = Reflection::GetType(className);
                lookedUpBy = "className";
                if (ty is null) {
                    return MakeError("unknown class: " + className, "UNKNOWN_TYPE", false, "",
                        "Reflection::GetType returned null. Class names are exact (e.g. CGameCtnChallenge).");
                }
            }
        }

        if (ty is null && input.HasKey("classId")) {
            uint64 id64 = 0;
            if (!TryParsePtr(input["classId"], id64)) {
                return MakeError("malformed classId (use integer or 0x... hex)", "BAD_CLASS_ID");
            }
            @ty = Reflection::GetType(uint(id64));
            lookedUpBy = "classId";
            if (ty is null) {
                return MakeError("unknown class id: " + TypeInfoHex32(uint(id64)), "UNKNOWN_TYPE");
            }
        }

        if (ty is null && input.HasKey("from")) {
            string from = string(input["from"]).Trim();
            if (from.Length > 0) {
                string errCode = "";
                string err = "";
                CMwNod@ nod = TypeInfoResolveFrom(from, errCode, err);
                if (nod is null) return MakeError(err, errCode);
                @ty = Reflection::TypeOf(nod);
                lookedUpBy = "from";
                if (ty is null) return MakeError("TypeOf returned null for from=" + from, "UNKNOWN_TYPE");
            }
        }

        if (ty is null) {
            return MakeError(
                "need className, classId, or from",
                "MISSING_LOOKUP",
                false,
                "",
                "Default: GetTypeInfo {className:'CGameCtnChallenge'} returns the class plus all members."
            );
        }

        bool ownOnly = input.HasKey("ownOnly") && bool(input["ownOnly"]);
        string queryLower = "";
        if (input.HasKey("query")) queryLower = string(input["query"]).ToLower();
        int limit = 0;
        if (input.HasKey("limit")) limit = int(input["limit"]);
        if (limit < 0) limit = 0;

        Json::Value output = TypeInfoClassJson(ty);
        output["lookedUpBy"] = lookedUpBy;
        output["ownOnly"] = ownOnly;
        // Openplanet MwMemberInfo has no member type name — only Name / Offset / ID.
        output["note"] = "MwMemberInfo has no member type name; isField=false (offset 0xFFFF) is typically a method.";

        Json::Value members = Json::Array();
        int matched = 0;
        bool found = true;

        if (input.HasKey("member")) {
            string memberName = string(input["member"]);
            const Reflection::MwClassInfo@ declared = ty;
            const Reflection::MwMemberInfo@ mem = null;
            if (ownOnly) {
                @mem = TypeInfoOwnMember(ty, memberName);
            } else {
                @mem = ty.GetMember(memberName);
                while (declared !is null) {
                    if (TypeInfoOwnMember(declared, memberName) !is null) break;
                    @declared = declared.BaseType;
                }
            }
            if (mem is null) {
                found = false;
            } else if (TypeInfoMemberMatches(mem, queryLower)) {
                matched = 1;
                if (declared is null) @declared = ty;
                members.Add(TypeInfoMemberJson(mem, string(declared.Name)));
            }
            output["found"] = found;
        } else {
            matched = TypeInfoAppendClassMembers(ty, members, queryLower, limit, !ownOnly);
        }

        output["members"] = members;
        output["memberCount"] = matched;
        output["returned"] = int(members.Length);
        output["truncated"] = matched > int(members.Length);
        return MakeSuccess(output);
    }
}
