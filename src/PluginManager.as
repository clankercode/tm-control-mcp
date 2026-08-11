namespace TmMcp {
    // Openplanet Meta:: plugin + settings surface for agents.
    // Docs: https://openplanet.dev/docs/api/Meta

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
        o["sourcePath"] = p.SourcePath;
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
                    o["path"] = u.Path;
                    string uid = string(o["id"]);
                    string upath = string(o["path"]);
                    if (q.Length == 0
                        || uid.ToLower().IndexOf(q) >= 0
                        || upath.ToLower().IndexOf(q) >= 0) {
                        unloaded.Add(o);
                    }
                }
            }
        }

        Json::Value output = Json::Object();
        output["plugins"] = plugins;
        output["count"] = plugins.Length;
        if (includeUnloaded) {
            output["unloaded"] = unloaded;
            output["unloadedCount"] = unloaded.Length;
        }
        auto self = Meta::ExecutingPlugin();
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
        Json::Value output = PluginToJson(p, true);
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
            return MakeError("action required", "bad_request", false, "", "enable|disable|reload|unload|load|openSettings|setEnabled");
        }
        string act = action.ToLower();

        if (act == "load") {
            string path = input.HasKey("path") ? string(input["path"]) : "";
            if (path.Length == 0) return MakeError("path required for load", "bad_request", false, "", "Absolute path to folder or .op/.zip");
            string sourceS = input.HasKey("source") ? string(input["source"]) : "UserFolder";
            string typeS = input.HasKey("type") ? string(input["type"]) : "Folder";
            Meta::PluginSource source = Meta::PluginSource::UserFolder;
            if (sourceS == "ApplicationFolder" || sourceS.ToLower() == "application") source = Meta::PluginSource::ApplicationFolder;
            Meta::PluginType ptype = Meta::PluginType::Folder;
            if (typeS == "Zip" || typeS.ToLower() == "zip" || typeS.ToLower() == "op") ptype = Meta::PluginType::Zip;
            try {
                auto loaded = Meta::LoadPlugin(path, source, ptype);
                if (loaded is null) return MakeError("LoadPlugin returned null", "load_failed", true, "", "Check path/source/type");
                Json::Value output = Json::Object();
                output["action"] = "load";
                output["plugin"] = PluginToJson(loaded);
                output["note"] = "Plugin loaded into memory";
                return MakeSuccess(output);
            } catch {
                return MakeError("LoadPlugin exception: " + getExceptionInfo(), "load_failed", true, "", "Path must be absolute");
            }
        }

        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        else if (input.HasKey("name")) id = string(input["name"]);
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        auto self = Meta::ExecutingPlugin();
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
            try {
                Meta::ReloadPlugin(p);
            } catch {
                return MakeError("ReloadPlugin failed: " + getExceptionInfo(), "plugin_control_failed", true, "", "");
            }
            output["queued"] = true;
            output["note"] = "Reload queued; Plugin handle invalid next frame";
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

        return MakeError("unknown action: " + action, "bad_request", false, "", "enable|disable|reload|unload|load|openSettings|setEnabled");
    }

    Json::Value@ ListPluginSettings(Json::Value &in input) {
        string id = "";
        if (input.HasKey("id")) id = string(input["id"]);
        else if (input.HasKey("plugin")) id = string(input["plugin"]);
        else if (input.HasKey("name")) id = string(input["name"]);
        if (id.Length == 0) {
            auto self = Meta::ExecutingPlugin();
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
            auto self = Meta::ExecutingPlugin();
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
            auto self = Meta::ExecutingPlugin();
            if (self !is null) id = self.ID;
        }
        string err = "";
        auto p = ResolvePlugin(id, err);
        if (p is null) return MakeError(err, "not_found", false, "", "Use ListPlugins");

        auto s = p.GetSetting(varName);
        if (s is null) return MakeError("setting not found: " + varName, "not_found", false, "", "Use ListPluginSettings for varName");

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
        output["note"] = "Some settings (e.g. socket host/port) require plugin reload to take effect";
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
            auto self = Meta::ExecutingPlugin();
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
