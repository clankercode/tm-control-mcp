namespace TmMcp {
    // GetInputBindings: the input devices the game sees and what each pad has bound.
    // Read-only: it never changes a binding or a setting.
    //
    // Devices: app.InputPort.ConnectedDevices (CInputDevice: engine-level keyboard, mouse,
    // DirectInput pads) and app.InputPort.Script_Pads (CInputScriptPad: the pads that
    // bindings are keyed by).
    // Bindings: CGameManiaPlanetScriptAPI.InputBindings_UpdateList(All, pad) fills
    // InputBindings_ActionNames / _Bindings / _BindingsRaw, one row per action, the same
    // call Settings > Controls makes per controller. Those lists are shared with that page
    // and with other plugins, so the list found on entry is put back afterwards.
    // Named ids: CInputScriptManager.GetActionBinding(pad, "Vehicle", id), the call the
    // race UI makes for its GiveUp / Respawn hints; it needs a ManiaApp's Input.

    Json::Value@ _BindingsDevice(CInputDevice@ d, uint index) {
        Json::Value o = Json::Object();
        o["index"] = int(index);
        if (d is null) { o["null"] = true; return o; }
        auto ty = Reflection::TypeOf(d);
        o["class"] = ty is null ? "" : string(ty.Name);
        o["instanceName"] = string(d.InstanceName);
        o["modelName"] = string(d.DeviceModelName);
        o["instanceId"] = d.InstanceId.GetName();
        o["modelId"] = d.DeviceModelId.GetName();
        o["disabled"] = d.IsDisabled;
        o["inputNotAvailable"] = d.InputNotAvailable;
        o["unplugged"] = d.IsUnPlugged;
        o["canRumble"] = d.CanRumble;
        o["objectCount"] = int(d.ObjectCount);
        return o;
    }

    void _BindingsHeld(Json::Value &inout held, uint value, const string &in name) {
        if (value != 0) held.Add(name);
    }

    void _BindingsAxis(Json::Value &inout axes, float value, const string &in name) {
        if (Math::Abs(value) > 0.05) axes[name] = value;
    }

    // What the pad is pressing right now: a phantom device that sends input shows up here.
    void _BindingsPadState(Json::Value &inout o, CInputScriptPad@ pad) {
        Json::Value held = Json::Array();
        _BindingsHeld(held, pad.Left, "Left"); _BindingsHeld(held, pad.Right, "Right");
        _BindingsHeld(held, pad.Up, "Up"); _BindingsHeld(held, pad.Down, "Down");
        _BindingsHeld(held, pad.A, "A"); _BindingsHeld(held, pad.B, "B");
        _BindingsHeld(held, pad.X, "X"); _BindingsHeld(held, pad.Y, "Y");
        _BindingsHeld(held, pad.L1, "L1"); _BindingsHeld(held, pad.R1, "R1");
        _BindingsHeld(held, pad.LeftStickBut, "LeftStickBut"); _BindingsHeld(held, pad.RightStickBut, "RightStickBut");
        _BindingsHeld(held, pad.Menu, "Menu"); _BindingsHeld(held, pad.View, "View");
        Json::Value axes = Json::Object();
        _BindingsAxis(axes, pad.LeftStickX, "LeftStickX"); _BindingsAxis(axes, pad.LeftStickY, "LeftStickY");
        _BindingsAxis(axes, pad.RightStickX, "RightStickX"); _BindingsAxis(axes, pad.RightStickY, "RightStickY");
        _BindingsAxis(axes, pad.L2, "L2"); _BindingsAxis(axes, pad.R2, "R2");
        o["idleMs"] = int(pad.IdleDuration);
        o["held"] = held;
        o["axes"] = axes;
    }

    bool _BindingsUpdateList(CGameManiaPlanetScriptAPI@ api, CInputScriptPad@ pad, string &out err) {
        err = "";
        try {
            api.InputBindings_UpdateList(CGameManiaPlanetScriptAPI::EInputsListFilter::All, pad);
            return true;
        } catch {
            err = getExceptionInfo();
            return false;
        }
    }

    string _BindingsRawSignature(CGameManiaPlanetScriptAPI@ api) {
        array<string> raws;
        for (uint i = 0; i < api.InputBindings_BindingsRaw.Length; i++) raws.InsertLast(api.InputBindings_BindingsRaw[i]);
        return BindingListSignature(raws);
    }

    // The list InputBindings_UpdateList just filled, as rows.
    void _BindingsList(Json::Value &inout o, CGameManiaPlanetScriptAPI@ api, const string &in filterLower, bool boundOnly) {
        uint n = api.InputBindings_ActionNames.Length;
        if (api.InputBindings_Bindings.Length < n) n = api.InputBindings_Bindings.Length;
        if (api.InputBindings_BindingsRaw.Length < n) n = api.InputBindings_BindingsRaw.Length;
        uint player = api.InputBindings_PlayerInputsCount;
        uint bound = 0;
        Json::Value rows = Json::Array();
        for (uint i = 0; i < n; i++) {
            string action = BindingActionName(string(api.InputBindings_ActionNames[i]));
            string display = string(api.InputBindings_Bindings[i]);
            string raw = api.InputBindings_BindingsRaw[i];
            if (display.Length > 0 || raw.Length > 0) bound++;
            if (!BindingRowKept(action.ToLower(), display.ToLower(), raw.ToLower(), filterLower, boundOnly)) continue;
            Json::Value row = Json::Object();
            row["index"] = int(i);
            row["action"] = action;
            row["player"] = i < player;
            row["display"] = display;
            row["raw"] = raw;
            rows.Add(row);
        }
        o["actionCount"] = int(n);
        o["playerActionCount"] = int(player);
        o["boundCount"] = int(bound);
        o["bindings"] = rows;
    }

    CInputScriptManager@ _BindingsInputManager(CTrackMania@ app, string &out source) {
        source = "";
        auto net = app.Network;
        if (net !is null && net.ClientManiaAppPlayground !is null && net.ClientManiaAppPlayground.Input !is null) {
            source = "playground";
            return net.ClientManiaAppPlayground.Input;
        }
        auto menus = app.MenuManager;
        if (menus !is null && menus.MenuCustom_CurrentManiaApp !is null && menus.MenuCustom_CurrentManiaApp.Input !is null) {
            source = "menu";
            return menus.MenuCustom_CurrentManiaApp.Input;
        }
        return null;
    }

    Json::Value@ GetInputBindings(Json::Value &in input) {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null) return MakeError("no app");
        auto port = app.InputPort;
        if (port is null) return MakeError("app.InputPort is not available", "INPUT_UNAVAILABLE", true);

        string filterLower = input.HasKey("filter") ? string(input["filter"]).ToLower() : "";
        bool boundOnly = input.HasKey("boundOnly") && bool(input["boundOnly"]);
        string actionMap = input.HasKey("actionMap") ? string(input["actionMap"]) : "Vehicle";
        array<string> ids = {"GiveUp", "Respawn", "SecondaryRespawn"};
        if (input.HasKey("actionIds")) {
            ids.RemoveRange(0, ids.Length);
            auto arr = input["actionIds"];
            for (uint i = 0; i < arr.Length && i < 32; i++) {
                if (arr[i].GetType() != Json::Type::String) return MakeError("actionIds must be strings", "INVALID_INPUT");
                ids.InsertLast(string(arr[i]));
            }
        }

        Json::Value output = Json::Object();
        Json::Value po = Json::Object();
        auto portTy = Reflection::TypeOf(port);
        po["class"] = portTy is null ? "" : string(portTy.Name);
        po["currentActionMap"] = port.CurrentActionMap;
        po["isFocused"] = port.IsFocused;
        po["ignoreFocusForGamePads"] = port.IgnoreFocusForGamePads;
        po["deviceHasBeenHotPlugged"] = port.DeviceHasBeenHotPlugged;
        po["devicePlugEventCount"] = int(port.DevicePlugEventCount);
        output["port"] = po;

        Json::Value devices = Json::Array();
        for (uint i = 0; i < port.ConnectedDevices.Length; i++) devices.Add(_BindingsDevice(port.ConnectedDevices[i], i));
        output["deviceCount"] = int(port.ConnectedDevices.Length);
        output["devices"] = devices;

        string namedSource;
        auto mgr = _BindingsInputManager(app, namedSource);
        Json::Value named = Json::Object();
        named["actionMap"] = actionMap;
        named["source"] = namedSource;
        if (mgr is null) {
            named["note"] = "no ManiaApp input manager here (needs the main menu or a playground); pads have no 'named'";
        } else {
            try {
                Json::Value names = Json::Object();
                for (uint k = 0; k < ids.Length; k++) names[ids[k]] = string(mgr.GetActionDisplayName(actionMap, ids[k]));
                named["displayNames"] = names;
            } catch {
                named["error"] = getExceptionInfo();
                @mgr = null;
            }
        }
        output["named"] = named;

        auto api = app.ManiaPlanetScriptAPI;
        string before = api is null ? "" : _BindingsRawSignature(api);
        bool wasEmpty = api is null || api.InputBindings_BindingsRaw.Length == 0;
        auto pads = port.Script_Pads;
        array<string> padSigs;
        Json::Value padsOut = Json::Array();
        for (uint i = 0; i < pads.Length; i++) {
            auto pad = pads[i];
            Json::Value p = Json::Object();
            p["index"] = int(i);
            padSigs.InsertLast("");
            if (pad is null) { p["null"] = true; padsOut.Add(p); continue; }
            p["controllerId"] = pad.ControllerId;
            p["type"] = tostring(pad.Type);
            p["modelName"] = string(pad.ModelName);
            p["userId"] = pad.UserId.GetName();
            _BindingsPadState(p, pad);
            if (mgr !is null) {
                try {
                    Json::Value nb = Json::Object();
                    for (uint k = 0; k < ids.Length; k++) {
                        Json::Value b = Json::Object();
                        b["display"] = string(mgr.GetActionBinding(pad, actionMap, ids[k]));
                        b["raw"] = mgr.GetActionBindingRaw(pad, actionMap, ids[k]);
                        nb[ids[k]] = b;
                    }
                    p["named"] = nb;
                } catch {
                    p["namedError"] = getExceptionInfo();
                }
            }
            if (api !is null) {
                string err;
                if (_BindingsUpdateList(api, pad, err)) {
                    _BindingsList(p, api, filterLower, boundOnly);
                    padSigs[i] = _BindingsRawSignature(api);
                } else {
                    p["bindingsError"] = err;
                }
            }
            padsOut.Add(p);
        }
        output["padCount"] = int(pads.Length);
        output["pads"] = padsOut;

        if (api is null) {
            output["bindingsError"] = "ManiaPlanetScriptAPI is not available";
            return MakeSuccess(output);
        }
        // Device=null: what the game selects for it is not verified (BindingsManager reads it as the keyboard list).
        Json::Value noDevice = Json::Object();
        string err;
        if (_BindingsUpdateList(api, null, err)) {
            _BindingsList(noDevice, api, filterLower, boundOnly);
        } else {
            noDevice["bindingsError"] = err;
        }
        output["noDevice"] = noDevice;

        // Put back the list found on entry: refill it for a pad that gives the same content.
        Json::Value sharedList = Json::Object();
        sharedList["wasEmpty"] = wasEmpty;
        bool restored = _BindingsRawSignature(api) == before;
        int match = padSigs.Find(before);
        if (!restored && match >= 0) {
            restored = _BindingsUpdateList(api, pads[uint(match)], err) && _BindingsRawSignature(api) == before;
            sharedList["refilledFor"] = "pad " + match;
        }
        sharedList["restored"] = restored;
        output["sharedList"] = sharedList;
        return MakeSuccess(output);
    }
}
