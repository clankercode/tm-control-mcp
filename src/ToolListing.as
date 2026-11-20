// ListTools and pack source locations. Host-only; uses Openplanet file/log APIs,
// so it stays out of ToolPacks.as (which also compiles in stock AngelScript tests).

namespace TmMcp {
    // "#2  void Ns::Fn() (C:/.../Plugins/pack/Pack.as line 55)" -> {function, file, line}
    Json::Value@ ParseStackFrame(const string &in logLine) {
        int hash = logLine.IndexOf("]      #");
        int open = logLine.LastIndexOf(" (");
        int at = logLine.LastIndexOf(" line ");
        if (hash < 0 || open < hash || at < open || !logLine.EndsWith(")")) return null;
        string head = logLine.SubStr(hash + 8, open - hash - 8);
        int gap = head.IndexOf("  ");
        int line = 0;
        if (gap < 0 || !Text::TryParseInt(logLine.SubStr(at + 6, logLine.Length - at - 7), line)) return null;
        auto frame = Json::Object();
        frame["function"] = head.SubStr(gap + 2).Trim();
        frame["file"] = logLine.SubStr(open + 2, at - open - 2);
        frame["line"] = line;
        return frame;
    }

    // Where a pack registers itself. Registration is an imported call, so it
    // runs on the pack's context: PrintActiveContextStack logs the pack's own
    // frames, and the log tail is the only place a script can read them back
    // (getExceptionInfo is the message alone). Costs one marker plus one line
    // per frame per registration; null when the log cannot be read or parsed.
    Json::Value@ CapturePackLocation(const string &in packId, const string &in generation) {
        string marker = "TM Control MCP pack " + packId + " g" + generation + " registered from:";
        trace(marker);
        PrintActiveContextStack();
        try {
            // The game holds the log open; a plain read is denied.
            IO::File f(IO::FromDataFolder("Openplanet.log"), IO::FileMode::Read, IO::ShareMode::DenyNone);
            uint64 size = f.Size();
            if (size > 16384) f.SetPos(size - 16384);
            string body = f.ReadToEnd();
            f.Close();
            int start = body.LastIndexOf(marker);
            if (start < 0) return null;
            auto lines = body.SubStr(start).Split("\n");
            string hostDir = "";
            for (uint i = 1; i < lines.Length; i++) {
                auto frame = ParseStackFrame(lines[i].Trim());
                if (frame is null) break;
                string file = frame["file"];
                string dir = file.SubStr(0, file.LastIndexOf("/") + 1);
                if (i == 1) hostDir = dir;       // #0 is this file
                else if (dir != hostDir) return frame;
            }
        } catch {
            trace("TM Control MCP pack location unavailable: " + getExceptionInfo());
        }
        return null;
    }

    // Every callable tool with its owner. input: {pack?, includeSchemas?}.
    Json::Value@ ListTools(Json::Value &in input) {
        string only = input.HasKey("pack") ? string(input["pack"]) : "";
        bool full = input.HasKey("includeSchemas") && bool(input["includeSchemas"]);
        auto self = SelfPlugin();
        string selfId = self is null ? "" : self.ID;
        auto all = GetToolListCached();
        auto tools = Json::Array();
        for (uint i = 0; i < all.Length; i++) {
            auto src = all[i];
            string packId = src.HasKey("pack") ? string(src["pack"]) : "";
            int idx = packId.Length > 0 ? FindPackIndex(packId) : -1;
            if (packId.Length == 0) packId = "core";
            if (only.Length > 0 && only != packId) continue;
            auto t = Json::Object();
            t["name"] = string(src["name"]);
            t["pack"] = packId;
            t["plugin"] = idx < 0 ? selfId : g_Packs[uint(idx)].pluginId;
            string desc = src["description"];
            if (full) t["input_schema"] = src["input_schema"];
            else if (desc.Length > 160) desc = desc.SubStr(0, 157) + "...";
            t["description"] = desc;
            tools.Add(t);
        }
        auto packs = Json::Object();
        for (uint i = 0; i < g_Packs.Length; i++) {
            auto pack = g_Packs[i];
            if (only.Length > 0 && only != pack.packId) continue;
            auto o = Json::Object();
            o["plugin"] = pack.pluginId;
            o["generation"] = pack.generation;
            o["toolCount"] = int(pack.toolNames.Length);
            if (pack.definedAt !is null) o["definedAt"] = pack.definedAt;
            packs[pack.packId] = o;
        }
        auto output = Json::Object();
        output["tools"] = tools;
        output["packs"] = packs;
        output["corePlugin"] = selfId;
        output["count"] = int(tools.Length);
        return MakeSuccess(output);
    }
}
