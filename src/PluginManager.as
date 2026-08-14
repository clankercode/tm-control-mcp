namespace TmMcp {
    // Openplanet Meta:: plugin + settings surface for agents.
    // Docs: https://openplanet.dev/docs/api/Meta

    // Cached handle to THIS plugin. Meta::ExecutingPlugin() returns the caller's
    // plugin when an exported function is invoked in-process from another plugin,
    // so "self" must be resolved once at startup, not per-call.
    Meta::Plugin@ g_SelfPlugin = null;

    // When true, PluginToJson includes full SourcePath (may be Wine absolute).
    bool g_IncludePluginSourcePath = false;

    void CacheSelfPlugin() {
        @g_SelfPlugin = Meta::ExecutingPlugin();
    }

    Meta::Plugin@ SelfPlugin() {
        if (g_SelfPlugin is null) CacheSelfPlugin();
        return g_SelfPlugin;
    }

    string SourcePathBaseName(const string &in path) {
        string p = path;
        while (p.Length > 0) {
            string last = p.SubStr(p.Length - 1, 1);
            if (last == "/" || last == "\\") p = p.SubStr(0, p.Length - 1);
            else break;
        }
        if (p.Length == 0) return "";
        int slash = p.LastIndexOf("/");
        int bslash = p.LastIndexOf("\\");
        int cut = slash;
        if (bslash > cut) cut = bslash;
        if (cut < 0) return p;
        if (cut + 1 >= int(p.Length)) return "";
        return p.SubStr(cut + 1);
    }

    string NormalizePluginPath(const string &in path) {
        string p = path.Replace("\\", "/");
        while (p.Length > 0 && p.SubStr(p.Length - 1, 1) == "/") {
            p = p.SubStr(0, p.Length - 1);
        }
        return p.ToLower();
    }

    string PluginStemFromPath(const string &in path) {
        string stem = SourcePathBaseName(path);
        string low = stem.ToLower();
        if (low.EndsWith(".op")) return stem.SubStr(0, stem.Length - 3);
        if (low.EndsWith(".zip")) return stem.SubStr(0, stem.Length - 4);
        return stem;
    }

    bool IsSafePluginId(const string &in id) {
        if (id.Length == 0) return false;
        string t = id.Trim();
        if (t.Length == 0) return false;
        if (t == "." || t == "..") return false;
        if (t.Contains("..") || t.Contains("/") || t.Contains("\\")) return false;
        bool onlyDots = true;
        for (uint i = 0; i < t.Length; i++) {
            string ch = t.SubStr(i, 1);
            if (ch != "." && ch != " " && ch != "\t") {
                onlyDots = false;
                break;
            }
        }
        return !onlyDots;
    }

    bool LineLooksLikeLoaded(const string &in line) {
        return line.Contains("Loaded plugin '")
            || line.Contains("Loaded zipped plugin '")
            || line.Contains("Loaded legacy plugin '");
    }

    bool LineLooksLikeCompileLog(const string &in line) {
        return line.Contains(" ERR ")
            || line.Contains(":  ERR :")
            || line.Contains(" WARN ")
            || line.Contains(": WARN :")
            || LineLooksLikeLoaded(line)
            || line.Contains("Script compilation")
            || line.Contains("Starting build")
            || line.Contains("compilation failed");
    }

    bool LineLooksLikeCompileFail(const string &in line) {
        return line.Contains(":  ERR :")
            || line.Contains(" ERR ")
            || line.Contains("compilation failed")
            || line.Contains("Script compilation failed");
    }

    Meta::Plugin@ FindLoadedPluginForRebuild(const string &in pluginId, const string &in path) {
        if (pluginId.Length > 0) {
            auto byId = Meta::GetPluginFromID(pluginId);
            if (byId !is null) return byId;
        }
        auto all = Meta::AllPlugins();
        if (all is null) return null;
        string wantPath = NormalizePluginPath(path);
        string wantStem = pluginId.Length > 0 ? pluginId : PluginStemFromPath(path);
        string wantBase = SourcePathBaseName(path);
        for (uint i = 0; i < all.Length; i++) {
            auto p = all[i];
            if (p is null) continue;
            if (wantStem.Length > 0 && p.ID == wantStem) return p;
            string src = NormalizePluginPath(p.SourcePath);
            if (wantPath.Length > 0 && src.Length > 0 && src == wantPath) return p;
            string srcBase = SourcePathBaseName(p.SourcePath);
            if (wantBase.Length > 0 && srcBase == wantBase) return p;
            if (wantStem.Length > 0 && srcBase == wantStem) return p;
        }
        return null;
    }

    bool IsSelfPluginTarget(const string &in pluginId, const string &in path) {
        auto self = SelfPlugin();
        if (self is null) return false;
        if (pluginId.Length > 0 && pluginId == self.ID) return true;
        string stem = PluginStemFromPath(path);
        if (stem.Length > 0 && stem == self.ID) return true;
        string selfPath = NormalizePluginPath(self.SourcePath);
        string want = NormalizePluginPath(path);
        if (selfPath.Length > 0 && want.Length > 0) {
            if (selfPath == want) return true;
            if (selfPath.StartsWith(want + "/") || want.StartsWith(selfPath + "/")) return true;
        }
        return false;
    }

    // Unload the plugin that owns path/id so LoadPlugin can reopen a locked .op.
    string UnloadIfLoadedForRebuild(const string &in pluginId, const string &in path, bool &out rebuilt) {
        rebuilt = false;
        if (IsSelfPluginTarget(pluginId, path)) {
            return "refusing to unload+load the executing MCP plugin";
        }
        auto existing = FindLoadedPluginForRebuild(pluginId, path);
        if (existing is null) return "";
        auto self = SelfPlugin();
        if (self !is null && existing.ID == self.ID) {
            return "refusing to unload+load the executing MCP plugin";
        }
        try {
            Meta::UnloadPlugin(existing);
            @existing = null;
            yield();
            rebuilt = true;
        } catch {
            return "UnloadPlugin before load failed: " + getExceptionInfo();
        }
        return "";
    }

    Json::Value@ CollectPluginLogLines(const string &in pluginId, uint maxLines, bool compileOnly) {
        Json::Value report = Json::Object();
        Json::Value lines = Json::Array();
        string path = IO::FromDataFolder("Openplanet.log");
        report["logPathBase"] = "Openplanet.log";
        if (!IO::FileExists(path)) {
            report["error"] = "Openplanet.log not found";
            report["lines"] = lines;
            report["count"] = 0;
            return report;
        }

        string body = "";
        try {
            IO::File f(path, IO::FileMode::Read);
            body = f.ReadToEnd();
            f.Close();
        } catch {
            report["error"] = "failed to read Openplanet.log: " + getExceptionInfo();
            report["lines"] = lines;
            report["count"] = 0;
            return report;
        }

        const int tailCap = 524288;
        if (int(body.Length) > tailCap) {
            body = body.SubStr(int(body.Length) - tailCap);
            report["truncated"] = true;
        }

        array<string>@ rawLines = body.Split("\n");
        array<string> compileLines;
        for (uint i = 0; i < rawLines.Length; i++) {
            string line = rawLines[i];
            if (line.Length > 0 && line.SubStr(line.Length - 1, 1) == "\r") {
                line = line.SubStr(0, line.Length - 1);
            }
            if (compileOnly) {
                if (LineLooksLikeCompileLog(line)) compileLines.InsertLast(line);
            } else if (pluginId.Length == 0 || line.Contains(pluginId)) {
                compileLines.InsertLast(line);
            }
        }

        int sessionStart = -1;
        string startNeedle1 = "Starting build for \"" + pluginId + "\"";
        string startNeedle2 = "Starting build for '" + pluginId + "'";
        for (uint i = 0; i < compileLines.Length; i++) {
            if (pluginId.Length > 0 && (compileLines[i].Contains(startNeedle1) || compileLines[i].Contains(startNeedle2))) {
                sessionStart = int(i);
            }
        }
        int sessionEnd = int(compileLines.Length);
        if (sessionStart >= 0) {
            for (uint i = uint(sessionStart) + 1; i < compileLines.Length; i++) {
                if (compileLines[i].Contains("Starting build for ") && !compileLines[i].Contains(pluginId)) {
                    sessionEnd = int(i);
                    break;
                }
                if ((compileLines[i].Contains(startNeedle1) || compileLines[i].Contains(startNeedle2)) && int(i) != sessionStart) {
                    sessionEnd = int(i);
                    break;
                }
            }
        }

        array<string> session;
        if (sessionStart >= 0) {
            for (int i = sessionStart; i < sessionEnd; i++) {
                session.InsertLast(compileLines[i]);
            }
        } else {
            for (uint i = 0; i < compileLines.Length; i++) {
                if (pluginId.Length == 0 || compileLines[i].Contains(pluginId) || LineLooksLikeCompileFail(compileLines[i])) {
                    session.InsertLast(compileLines[i]);
                }
            }
        }

        uint errorCount = 0;
        uint warnCount = 0;
        bool sawLoaded = false;
        bool sawFail = false;
        for (uint i = 0; i < session.Length; i++) {
            string line = session[i];
            if (line.Contains(" ERR ") || line.Contains(":  ERR :")) errorCount++;
            if (line.Contains(" WARN ") || line.Contains(": WARN :")) warnCount++;
            if (LineLooksLikeLoaded(line) && (pluginId.Length == 0 || line.Contains(pluginId))) sawLoaded = true;
            if (LineLooksLikeCompileFail(line)) sawFail = true;
        }

        uint start = 0;
        if (session.Length > maxLines) start = session.Length - maxLines;
        for (uint i = start; i < session.Length; i++) {
            if (compileOnly && pluginId.Length > 0 && !session[i].Contains(pluginId) && !LineLooksLikeCompileFail(session[i]) && !session[i].Contains("Starting build")) {
                continue;
            }
            lines.Add(session[i]);
        }
        report["lines"] = lines;
        report["count"] = lines.Length;
        report["matched"] = session.Length;
        report["errorCount"] = errorCount;
        report["warnCount"] = warnCount;
        report["loaded"] = sawLoaded;
        report["compileFailed"] = sawFail;
        return report;
    }

    // RemoteBuild-style path: user Plugins/<id>/ or <id>.op, or app Openplanet/Plugins/.
    string ResolveRemoteBuildPluginPath(
        const string &in pluginId,
        const string &in sourceS,
        const string &in typeS,
        string &out err,
        Meta::PluginSource &out source,
        Meta::PluginType &out ptype
    ) {
        err = "";
        source = Meta::PluginSource::UserFolder;
        ptype = Meta::PluginType::Folder;
        if (!IsSafePluginId(pluginId)) {
            err = "plugin id must be a folder/.op name (no path separators)";
            return "";
        }

        string srcNorm = sourceS.ToLower();
        string base = "";
        if (srcNorm.Length == 0 || srcNorm == "user" || srcNorm == "userfolder") {
            source = Meta::PluginSource::UserFolder;
            base = IO::FromDataFolder("Plugins/");
        } else if (srcNorm == "app" || srcNorm == "application" || srcNorm == "applicationfolder") {
            source = Meta::PluginSource::ApplicationFolder;
            base = IO::FromAppFolder("Openplanet/Plugins/");
        } else {
            err = "unknown source: " + sourceS + " (user|app)";
            return "";
        }

        string typeNorm = typeS.ToLower();
        string folderPath = base + pluginId;
        string zipPath = base + pluginId + ".op";
        bool folderOk = IO::FolderExists(folderPath) || IO::FolderExists(folderPath + "/");
        bool zipOk = IO::FileExists(zipPath);

        if (typeNorm == "folder" || typeNorm == "") {
            if (folderOk) {
                ptype = Meta::PluginType::Folder;
                return folderPath + "/";
            }
            if (typeNorm == "" && zipOk) {
                ptype = Meta::PluginType::Zip;
                return zipPath;
            }
            if (typeNorm == "folder") {
                err = "folder plugin not found: " + folderPath;
                return "";
            }
        }
        if (typeNorm == "zip" || typeNorm == "op") {
            if (zipOk) {
                ptype = Meta::PluginType::Zip;
                return zipPath;
            }
            err = "zip plugin not found: " + zipPath;
            return "";
        }
        if (typeNorm.Length > 0) {
            err = "unknown type: " + typeS + " (folder|zip)";
            return "";
        }
        err = "plugin not found under " + base + " as folder or .op: " + pluginId;
        return "";
    }

    Meta::Plugin@ ResolvePlugin(const string &in idOrName, string &out err) {
        err = "";
        if (idOrName.Length == 0) {
            err = "plugin id or name required";
            return null;
        }
        auto byId = Meta::GetPluginFromID(idOrName);
        if (byId !is null) return byId;

        auto all = Meta::AllPlugins();
        if (all is null) {
            err = "Meta::AllPlugins returned null";
            return null;
        }
        string want = idOrName.ToLower();
        Meta::Plugin@ nameMatch = null;
        uint nameHits = 0;
        for (uint i = 0; i < all.Length; i++) {
            auto p = all[i];
            if (p is null) continue;
            if (p.ID == idOrName) return p;
            if (p.Name == idOrName) {
                @nameMatch = p;
                nameHits++;
            } else if (p.Name.ToLower() == want) {
                @nameMatch = p;
                nameHits++;
            }
        }
        if (nameHits == 1) return nameMatch;
        if (nameHits > 1) {
            err = "multiple plugins match name '" + idOrName + "'; use exact plugin id";
            return null;
        }
        err = "plugin not found: " + idOrName;
        return null;
    }

    string PluginTypeToString(Meta::PluginType t) {
        if (t == Meta::PluginType::Folder) return "Folder";
        if (t == Meta::PluginType::Zip) return "Zip";
        return "Unknown";
    }

    string PluginSourceToString(Meta::PluginSource s) {
        if (s == Meta::PluginSource::ApplicationFolder) return "ApplicationFolder";
        if (s == Meta::PluginSource::UserFolder) return "UserFolder";
        return "Unknown";
    }

    string SettingTypeToString(Meta::PluginSettingType t) {
        if (t == Meta::PluginSettingType::Bool) return "Bool";
        if (t == Meta::PluginSettingType::Enum) return "Enum";
        if (t == Meta::PluginSettingType::Float) return "Float";
        if (t == Meta::PluginSettingType::Double) return "Double";
        if (t == Meta::PluginSettingType::Int8) return "Int8";
        if (t == Meta::PluginSettingType::Int16) return "Int16";
        if (t == Meta::PluginSettingType::Int32) return "Int32";
        if (t == Meta::PluginSettingType::String) return "String";
        if (t == Meta::PluginSettingType::Vec2) return "Vec2";
        if (t == Meta::PluginSettingType::Vec3) return "Vec3";
        if (t == Meta::PluginSettingType::Vec4) return "Vec4";
        if (t == Meta::PluginSettingType::Uint8) return "Uint8";
        if (t == Meta::PluginSettingType::Uint16) return "Uint16";
        if (t == Meta::PluginSettingType::Uint32) return "Uint32";
        return "Unknown";
    }

    Json::Value@ PluginToJson(Meta::Plugin@ p, bool includeSettingsCount = true) {
        Json::Value o = Json::Object();
        if (p is null) {
            o["null"] = true;
            return o;
        }
        o["id"] = p.ID;
        o["name"] = p.Name;
        o["author"] = p.Author;
        o["category"] = p.Category;
        o["version"] = p.Version;
        o["type"] = PluginTypeToString(p.Type);
        o["source"] = PluginSourceToString(p.Source);
        // Full SourcePath can be a Wine/Proton absolute path (user machine layout).
        // Always emit basename; full path only when includeSourcePath=true on GetPlugin.
        string srcPath = p.SourcePath;
        o["sourcePathBase"] = SourcePathBaseName(srcPath);
        if (g_IncludePluginSourcePath) {
            o["sourcePath"] = srcPath;
        }
        o["enabled"] = p.Enabled;
        o["favorite"] = p.Favorite;
        o["essential"] = p.Essential;
        o["unstable"] = p.Unstable;
        o["hasManifest"] = p.HasManifest;
        o["signatureLevel"] = p.SignatureLevel;
        o["siteId"] = p.SiteID;

        auto deps = p.Dependencies;
        Json::Value depsJ = Json::Array();
        if (deps !is null) {
            for (uint i = 0; i < deps.Length; i++) depsJ.Add(deps[i]);
        }
        o["dependencies"] = depsJ;

        auto opt = p.OptionalDependencies;
        Json::Value optJ = Json::Array();
        if (opt !is null) {
            for (uint i = 0; i < opt.Length; i++) optJ.Add(opt[i]);
        }
        o["optionalDependencies"] = optJ;

        if (includeSettingsCount) {
            auto settings = p.GetSettings();
            o["settingsCount"] = settings is null ? 0 : int(settings.Length);
        }
        return o;
    }

    Json::Value@ ReadSettingValue(Meta::PluginSetting@ s) {
        if (s is null) return Json::Value();
        auto t = s.Type;
        if (t == Meta::PluginSettingType::Bool) return Json::Value(s.ReadBool());
        if (t == Meta::PluginSettingType::Enum) {
            string enumName = "";
            int v = s.ReadEnum(enumName);
            Json::Value o = Json::Object();
            o["value"] = v;
            o["name"] = enumName;
            return o;
        }
        if (t == Meta::PluginSettingType::Float) return Json::Value(s.ReadFloat());
        if (t == Meta::PluginSettingType::Double) return Json::Value(s.ReadDouble());
        if (t == Meta::PluginSettingType::Int8) return Json::Value(int(s.ReadInt8()));
        if (t == Meta::PluginSettingType::Int16) return Json::Value(int(s.ReadInt16()));
        if (t == Meta::PluginSettingType::Int32) return Json::Value(s.ReadInt32());
        if (t == Meta::PluginSettingType::String) return Json::Value(s.ReadString());
        if (t == Meta::PluginSettingType::Vec2) {
            vec2 v = s.ReadVec2();
            Json::Value a = Json::Array();
            a.Add(v.x); a.Add(v.y);
            return a;
        }
        if (t == Meta::PluginSettingType::Vec3) {
            vec3 v = s.ReadVec3();
            Json::Value a = Json::Array();
            a.Add(v.x); a.Add(v.y); a.Add(v.z);
            return a;
        }
        if (t == Meta::PluginSettingType::Vec4) {
            vec4 v = s.ReadVec4();
            Json::Value a = Json::Array();
            a.Add(v.x); a.Add(v.y); a.Add(v.z); a.Add(v.w);
            return a;
        }
        if (t == Meta::PluginSettingType::Uint8) return Json::Value(int(s.ReadUint8()));
        if (t == Meta::PluginSettingType::Uint16) return Json::Value(int(s.ReadUint16()));
        if (t == Meta::PluginSettingType::Uint32) return Json::Value(int(s.ReadUint32()));
        return Json::Value();
    }

    Json::Value@ SettingToJson(Meta::PluginSetting@ s, bool includeValue = true) {
        Json::Value o = Json::Object();
        if (s is null) {
            o["null"] = true;
            return o;
        }
        o["varName"] = s.VarName;
        o["name"] = s.Name;
        o["namespace"] = s.Namespace;
        o["category"] = s.Category;
        o["description"] = s.Description;
        o["type"] = SettingTypeToString(s.Type);
        o["typeName"] = s.TypeName;
        o["visible"] = s.Visible;
        if (includeValue) {
            o["value"] = ReadSettingValue(s);
        }
        return o;
    }

    bool WriteSettingValue(Meta::PluginSetting@ s, Json::Value &in value, string &out err) {
        err = "";
        if (s is null) {
            err = "setting is null";
            return false;
        }
        auto t = s.Type;
        try {
            if (t == Meta::PluginSettingType::Bool) {
                if (value.GetType() != Json::Type::Boolean) {
                    err = "value must be boolean";
                    return false;
                }
                s.WriteBool(bool(value));
                return true;
            }
            if (t == Meta::PluginSettingType::Enum) {
                if (value.GetType() == Json::Type::Number) {
                    s.WriteEnum(int(value));
                    return true;
                }
                err = "enum value must be integer ordinal";
                return false;
            }
            if (t == Meta::PluginSettingType::Float) {
                s.WriteFloat(float(double(value)));
                return true;
            }
            if (t == Meta::PluginSettingType::Double) {
                s.WriteDouble(double(value));
                return true;
            }
            if (t == Meta::PluginSettingType::Int8) {
                s.WriteInt8(int8(int(value)));
                return true;
            }
            if (t == Meta::PluginSettingType::Int16) {
                s.WriteInt16(int16(int(value)));
                return true;
            }
            if (t == Meta::PluginSettingType::Int32) {
                s.WriteInt32(int(value));
                return true;
            }
            if (t == Meta::PluginSettingType::String) {
                if (value.GetType() != Json::Type::String) {
                    err = "value must be string";
                    return false;
                }
                s.WriteString(string(value));
                return true;
            }
            if (t == Meta::PluginSettingType::Vec2) {
                if (value.GetType() != Json::Type::Array || value.Length < 2) {
                    err = "vec2 value must be [x,y]";
                    return false;
                }
                s.WriteVec2(vec2(float(double(value[0])), float(double(value[1]))));
                return true;
            }
            if (t == Meta::PluginSettingType::Vec3) {
                if (value.GetType() != Json::Type::Array || value.Length < 3) {
                    err = "vec3 value must be [x,y,z]";
                    return false;
                }
                s.WriteVec3(vec3(float(double(value[0])), float(double(value[1])), float(double(value[2]))));
                return true;
            }
            if (t == Meta::PluginSettingType::Vec4) {
                if (value.GetType() != Json::Type::Array || value.Length < 4) {
                    err = "vec4 value must be [x,y,z,w]";
                    return false;
                }
                s.WriteVec4(vec4(float(double(value[0])), float(double(value[1])), float(double(value[2])), float(double(value[3]))));
                return true;
            }
            if (t == Meta::PluginSettingType::Uint8) {
                s.WriteUint8(uint8(int(value)));
                return true;
            }
            if (t == Meta::PluginSettingType::Uint16) {
                s.WriteUint16(uint16(int(value)));
                return true;
            }
            if (t == Meta::PluginSettingType::Uint32) {
                s.WriteUint32(uint(int(value)));
                return true;
            }
            err = "unsupported setting type: " + SettingTypeToString(t);
            return false;
        } catch {
            err = "write failed: " + getExceptionInfo();
            return false;
        }
    }

    Json::Value@ ListPlugins(Json::Value &in input) {
        bool includeDisabled = !(input.HasKey("includeDisabled") && !bool(input["includeDisabled"]));
        bool includeUnloaded = input.HasKey("includeUnloaded") && bool(input["includeUnloaded"]);
        string query = input.HasKey("query") ? string(input["query"]) : "";
        string q = query.ToLower();

        bool prevPath = g_IncludePluginSourcePath;
        g_IncludePluginSourcePath = input.HasKey("includeSourcePath") && bool(input["includeSourcePath"]);

        Json::Value plugins = Json::Array();
        auto all = Meta::AllPlugins();
        if (all !is null) {
            for (uint i = 0; i < all.Length; i++) {
                auto p = all[i];
                if (p is null) continue;
                if (!includeDisabled && !p.Enabled) continue;
                if (q.Length > 0) {
                    string hay = (p.ID + " " + p.Name + " " + p.Author + " " + p.Category).ToLower();
                    if (hay.IndexOf(q) < 0) continue;
                }
                plugins.Add(PluginToJson(p));
            }
        }

        Json::Value unloaded = Json::Array();
        if (includeUnloaded) {
            auto ul = Meta::UnloadedPlugins();
            if (ul !is null) {
                for (uint i = 0; i < ul.Length; i++) {
                    auto u = ul[i];
                    Json::Value o = Json::Object();
                    o["id"] = u.ID;
                    o["pathBase"] = SourcePathBaseName(u.Path);
                    if (g_IncludePluginSourcePath) {
                        o["path"] = u.Path;
                    }
                    string uid = u.ID;
                    string upath = u.Path;
                    if (q.Length == 0
                        || uid.ToLower().IndexOf(q) >= 0
                        || upath.ToLower().IndexOf(q) >= 0) {
                        unloaded.Add(o);
                    }
                }
            }
        }

        g_IncludePluginSourcePath = prevPath;

        Json::Value output = Json::Object();
        output["plugins"] = plugins;
        output["count"] = plugins.Length;
        if (includeUnloaded) {
            output["unloaded"] = unloaded;
            output["unloadedCount"] = unloaded.Length;
        }
        auto self = SelfPlugin();
        if (self !is null) output["selfId"] = self.ID;
        return MakeSuccess(output);
    }

    Json::Value@ GetPluginInfo(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        else if (input.HasKey("name")) id = string(input["name"]);
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins; match by id preferred");

        bool prevPath = g_IncludePluginSourcePath;
        g_IncludePluginSourcePath = input.HasKey("includeSourcePath") && bool(input["includeSourcePath"]);
        Json::Value output = PluginToJson(p, true);
        g_IncludePluginSourcePath = prevPath;

        bool withSettings = input.HasKey("includeSettings") && bool(input["includeSettings"]);
        if (withSettings) {
            Json::Value arr = Json::Array();
            auto settings = p.GetSettings();
            if (settings !is null) {
                for (uint i = 0; i < settings.Length; i++) {
                    arr.Add(SettingToJson(settings[i], true));
                }
            }
            output["settings"] = arr;
        }
        return MakeSuccess(output);
    }

    Json::Value@ ControlPlugin(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "";
        if (action.Length == 0) {
            return MakeError("action required", "bad_request", false, "", "enable|disable|reload|unload|load|openSettings|setEnabled|getLogs");
        }
        string act = action.ToLower();

        if (act == "load") {
            string path = input.HasKey("path") ? string(input["path"]) : "";
            string sourceS = input.HasKey("source") ? string(input["source"]) : "user";
            string typeS = input.HasKey("type") ? string(input["type"]) : "";
            string loadId = "";
            if (input.HasKey("id")) loadId = string(input["id"]);
            else if (input.HasKey("plugin")) loadId = string(input["plugin"]);

            Meta::PluginSource source = Meta::PluginSource::UserFolder;
            Meta::PluginType ptype = Meta::PluginType::Folder;
            bool rebuilt = false;

            if (path.Length == 0) {
                if (loadId.Length == 0) {
                    return MakeError("path or id required for load", "bad_request", false, "", "id=folder name (RemoteBuild-style) or absolute path");
                }
                string resolveErr = "";
                path = ResolveRemoteBuildPluginPath(loadId, sourceS, typeS, resolveErr, source, ptype);
                if (path.Length == 0) return MakeError(resolveErr, "not_found", false, "", "Use ListPlugins or check Plugins/<id>");
            } else {
                if (sourceS == "ApplicationFolder" || sourceS.ToLower() == "application" || sourceS.ToLower() == "app") {
                    source = Meta::PluginSource::ApplicationFolder;
                }
                string typeNorm = typeS.ToLower();
                string pathLower = path.ToLower();
                if (typeNorm == "zip" || typeNorm == "op" || pathLower.EndsWith(".op") || pathLower.EndsWith(".zip")) {
                    ptype = Meta::PluginType::Zip;
                }
                if (loadId.Length == 0) loadId = PluginStemFromPath(path);
            }

            if (IsSelfPluginTarget(loadId, path)) {
                return MakeError("refusing to unload+load the executing MCP plugin", "forbidden", false, "", "Use action=reload for self");
            }

            string unloadErr = UnloadIfLoadedForRebuild(loadId, path, rebuilt);
            if (unloadErr.Length > 0) {
                string code = unloadErr.StartsWith("refusing") ? "forbidden" : "plugin_control_failed";
                string hint = unloadErr.StartsWith("refusing") ? "Use action=reload for self" : ".op files are locked while loaded";
                return MakeError(unloadErr, code, !unloadErr.StartsWith("refusing"), "", hint);
            }

            string logId = loadId.Length > 0 ? loadId : PluginStemFromPath(path);
            try {
                auto loaded = Meta::LoadPlugin(path, source, ptype);
                if (loaded is null) {
                    Json::Value@ fail = MakeError("LoadPlugin returned null", "load_failed", true, "", "Check path/source/type; compile/getLogs for ScriptEngine errors");
                    Json::Value output = Json::Object();
                    output["action"] = "load";
                    output["compile"] = CollectPluginLogLines(logId, 40, true);
                    fail["output"] = output;
                    return fail;
                }
                yield();
                Json::Value output = Json::Object();
                output["action"] = "load";
                output["plugin"] = PluginToJson(loaded);
                output["rebuilt"] = rebuilt;
                output["note"] = rebuilt ? "Unloaded existing plugin then loaded from disk (RemoteBuild-style)" : "Plugin loaded into memory";
                if (logId.Length == 0) logId = loaded.ID;
                output["compile"] = CollectPluginLogLines(logId, 40, true);
                return MakeSuccess(output);
            } catch {
                Json::Value@ fail = MakeError("LoadPlugin exception: " + getExceptionInfo(), "load_failed", true, "", "Path must be absolute, or pass id=plugin folder name");
                Json::Value output = Json::Object();
                output["action"] = "load";
                output["compile"] = CollectPluginLogLines(logId, 40, true);
                fail["output"] = output;
                return fail;
            }
        }

        if (act == "getlogs" || act == "get_logs") {
            string logId = "";
            if (input.HasKey("id")) logId = string(input["id"]);
            else if (input.HasKey("plugin")) logId = string(input["plugin"]);
            else if (input.HasKey("name")) logId = string(input["name"]);
            if (logId.Length == 0) return MakeError("id required for getLogs", "bad_request", false, "", "Plugin folder/id to filter Openplanet.log");
            uint maxLines = 80;
            if (input.HasKey("maxLines")) {
                int n = int(input["maxLines"]);
                if (n < 1) n = 1;
                if (n > 400) n = 400;
                maxLines = uint(n);
            }
            bool compileOnly = !(input.HasKey("compileOnly") && !bool(input["compileOnly"]));
            Json::Value output = Json::Object();
            output["action"] = "getLogs";
            output["id"] = logId;
            output["compileOnly"] = compileOnly;
            Json::Value@ collected = CollectPluginLogLines(logId, maxLines, compileOnly);
            output["log"] = collected;
            return MakeSuccess(output);
        }

        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        else if (input.HasKey("name")) id = string(input["name"]);
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        auto self = SelfPlugin();
        bool isSelf = self !is null && p.ID == self.ID;

        Json::Value output = Json::Object();
        output["action"] = act;
        output["id"] = p.ID;
        output["name"] = p.Name;

        if (act == "opensettings" || act == "open_settings") {
            Meta::OpenSettings(p);
            output["opened"] = true;
            return MakeSuccess(output);
        }

        if (act == "enable" || act == "setenabled") {
            bool en = true;
            if (act == "setenabled") {
                if (!input.HasKey("enabled")) return MakeError("enabled bool required for setEnabled", "bad_request", false, "", "");
                en = bool(input["enabled"]);
            }
            if (isSelf && !en) {
                return MakeError("refusing to disable the executing MCP plugin", "forbidden", false, "", "Disable from Openplanet UI if intentional");
            }
            try {
                if (en) p.Enable();
                else p.Disable();
                // Enabled property may lag a frame; also set property
                p.Enabled = en;
            } catch {
                return MakeError("enable/disable failed: " + getExceptionInfo(), "plugin_control_failed", true, "", "");
            }
            output["enabled"] = en;
            output["note"] = "Enable/disable applied; some plugins apply on next frame";
            return MakeSuccess(output);
        }

        if (act == "disable") {
            if (isSelf) {
                return MakeError("refusing to disable the executing MCP plugin", "forbidden", false, "", "Disable from Openplanet UI if intentional");
            }
            try {
                p.Disable();
                p.Enabled = false;
            } catch {
                return MakeError("disable failed: " + getExceptionInfo(), "plugin_control_failed", true, "", "");
            }
            output["enabled"] = false;
            return MakeSuccess(output);
        }

        if (act == "reload") {
            if (isSelf) {
                output["warning"] = "Reloading self; socket will drop until plugin finishes reload";
            }
            string reloadId = p.ID;
            try {
                Meta::ReloadPlugin(p);
            } catch {
                return MakeError("ReloadPlugin failed: " + getExceptionInfo(), "plugin_control_failed", true, "", "");
            }
            output["queued"] = true;
            output["note"] = "Reload queued; Plugin handle invalid next frame";
            if (!isSelf) {
                yield();
                output["compile"] = CollectPluginLogLines(reloadId, 40, true);
            }
            return MakeSuccess(output);
        }

        if (act == "unload") {
            if (isSelf) {
                return MakeError("refusing to unload the executing MCP plugin", "forbidden", false, "", "Unload from Openplanet UI if intentional");
            }
            try {
                Meta::UnloadPlugin(p);
            } catch {
                return MakeError("UnloadPlugin failed: " + getExceptionInfo(), "plugin_control_failed", true, "", "");
            }
            output["queued"] = true;
            output["note"] = "Unload queued; Plugin handle invalid next frame";
            return MakeSuccess(output);
        }

        return MakeError("unknown action: " + action, "bad_request", false, "", "enable|disable|reload|unload|load|openSettings|setEnabled|getLogs");
    }

    Json::Value@ ListPluginSettings(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        else if (input.HasKey("name")) id = string(input["name"]);
        if (id.Length == 0) {
            auto self = SelfPlugin();
            if (self !is null) id = self.ID;
        }
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        string category = input.HasKey("category") ? string(input["category"]) : "";
        string query = input.HasKey("query") ? string(input["query"]) : "";
        string q = query.ToLower();
        bool includeHidden = input.HasKey("includeHidden") && bool(input["includeHidden"]);
        bool includeValues = !(input.HasKey("includeValues") && !bool(input["includeValues"]));

        Json::Value arr = Json::Array();
        auto settings = p.GetSettings();
        if (settings !is null) {
            for (uint i = 0; i < settings.Length; i++) {
                auto s = settings[i];
                if (s is null) continue;
                if (!includeHidden && !s.Visible) continue;
                if (category.Length > 0 && s.Category != category) continue;
                if (q.Length > 0) {
                    string hay = (s.VarName + " " + s.Name + " " + s.Category + " " + s.Description).ToLower();
                    if (hay.IndexOf(q) < 0) continue;
                }
                arr.Add(SettingToJson(s, includeValues));
            }
        }

        Json::Value output = Json::Object();
        output["pluginId"] = p.ID;
        output["pluginName"] = p.Name;
        output["settings"] = arr;
        output["count"] = arr.Length;
        return MakeSuccess(output);
    }

    Json::Value@ GetPluginSetting(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        string varName = "";
        if (input.HasKey("varName")) varName = string(input["varName"]);
        else if (input.HasKey("setting")) varName = string(input["setting"]);
        else if (input.HasKey("name")) varName = string(input["name"]);
        if (varName.Length == 0) return MakeError("varName required", "bad_request", false, "", "Use ListPluginSettings");

        if (id.Length == 0) {
            auto self = SelfPlugin();
            if (self !is null) id = self.ID;
        }
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        auto s = p.GetSetting(varName);
        if (s is null) {
            // fallback: match display name uniquely
            auto settings = p.GetSettings();
            Meta::PluginSetting@ byName = null;
            uint hits = 0;
            if (settings !is null) {
                for (uint i = 0; i < settings.Length; i++) {
                    auto cand = settings[i];
                    if (cand is null) continue;
                    if (cand.VarName == varName || cand.Name == varName) {
                        @byName = cand;
                        hits++;
                    }
                }
            }
            if (hits == 1) @s = byName;
            else if (hits > 1) return MakeError("multiple settings match '" + varName + "'", "ambiguous", false, "", "Use exact varName");
            else return MakeError("setting not found: " + varName, "not_found", false, "", "Use ListPluginSettings");
        }

        Json::Value output = SettingToJson(s, true);
        output["pluginId"] = p.ID;
        return MakeSuccess(output);
    }

    Json::Value@ SetPluginSetting(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        string varName = "";
        if (input.HasKey("varName")) varName = string(input["varName"]);
        else if (input.HasKey("setting")) varName = string(input["setting"]);
        if (varName.Length == 0) return MakeError("varName required", "bad_request", false, "", "");
        if (!input.HasKey("value")) return MakeError("value required", "bad_request", false, "", "");

        if (id.Length == 0) {
            auto self = SelfPlugin();
            if (self !is null) id = self.ID;
        }
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        auto s = p.GetSetting(varName);
        if (s is null) return MakeError("setting not found: " + varName, "not_found", false, "", "Use ListPluginSettings for varName");

        auto selfCheck = SelfPlugin();
        bool writingSelf = selfCheck !is null && p.ID == selfCheck.ID;
        if (writingSelf && varName == "S_TmMcpHost") {
            string want = string(input["value"]);
            if (want != "127.0.0.1") {
                return MakeError("only 127.0.0.1 is allowed as the bind host", "forbidden", false, "", "Localhost-only socket; no auth");
            }
        }
        if (writingSelf && varName == "S_TmMcpPort") {
            int port = int(input["value"]);
            if (port < 1 || port > 65535) {
                return MakeError("port must be 1-65535", "bad_value", false, "", "");
            }
        }

        string werr = "";
        if (!WriteSettingValue(s, input["value"], werr)) {
            return MakeError(werr, "bad_value", false, "", "Type=" + SettingTypeToString(s.Type));
        }

        bool save = !(input.HasKey("save") && !bool(input["save"]));
        if (save) {
            try { Meta::SaveSettings(); } catch {}
        }

        Json::Value output = Json::Object();
        output["pluginId"] = p.ID;
        output["varName"] = s.VarName;
        output["type"] = SettingTypeToString(s.Type);
        output["value"] = ReadSettingValue(s);
        output["saved"] = save;
        auto self = SelfPlugin();
        bool isSelf = self !is null && p.ID == self.ID;
        if (isSelf && (varName == "S_TmMcpEnableSocket" || varName == "S_TmMcpHost" || varName == "S_TmMcpPort")) {
            ApplySocketSettings();
            output["applied"] = true;
            output["note"] = "Socket enable/host/port apply live (no reload)";
            output["socket"] = GetSocketStatus();
        } else {
            output["note"] = "Some settings may need a plugin reload to take effect";
        }
        return MakeSuccess(output);
    }

    Json::Value@ ResetPluginSetting(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        string varName = "";
        if (input.HasKey("varName")) varName = string(input["varName"]);
        else if (input.HasKey("setting")) varName = string(input["setting"]);
        if (varName.Length == 0) return MakeError("varName required", "bad_request", false, "", "");

        if (id.Length == 0) {
            auto self = SelfPlugin();
            if (self !is null) id = self.ID;
        }
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "");

        auto s = p.GetSetting(varName);
        if (s is null) return MakeError("setting not found: " + varName, "not_found", false, "", "");
        try { s.Reset(); } catch {
            return MakeError("Reset failed: " + getExceptionInfo(), "reset_failed", true, "", "");
        }
        bool save = !(input.HasKey("save") && !bool(input["save"]));
        if (save) {
            try { Meta::SaveSettings(); } catch {}
        }
        Json::Value output = Json::Object();
        output["pluginId"] = p.ID;
        output["varName"] = s.VarName;
        output["value"] = ReadSettingValue(s);
        output["saved"] = save;
        return MakeSuccess(output);
    }

    Json::Value@ SavePluginSettings(Json::Value &in input) {
        try {
            Meta::SaveSettings();
        } catch {
            return MakeError("Meta::SaveSettings failed: " + getExceptionInfo(), "save_failed", true, "", "");
        }
        Json::Value output = Json::Object();
        output["saved"] = true;
        output["note"] = "Persisted Openplanet plugin settings to disk";
        return MakeSuccess(output);
    }
}
