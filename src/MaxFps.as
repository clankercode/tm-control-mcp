namespace TmMcp {
    // The game's frame limit: CSystemConfig.Display.MaxFps (the settings
    // menu's "Max FPS"). GetApp().SystemConfig and Viewport.SystemConfig are
    // the same object. A write takes effect on the next frame (verified
    // 2026-11-20 on a multibox instance: 40 -> 30 measured 29.9 fps, 0
    // uncapped at ~113) but is not saved to Default.json; the game keeps it
    // for the session unless something else writes the config.

    const uint MAX_FPS_MIN = 10;
    const uint MAX_FPS_MAX = 1000;

    // "" when fps is an accepted limit (0 = uncapped, else MIN..MAX).
    string MaxFpsInputError(int fps) {
        if (fps == 0) return "";
        if (fps < int(MAX_FPS_MIN) || fps > int(MAX_FPS_MAX))
            return "fps must be 0 (uncapped) or " + MAX_FPS_MIN + ".." + MAX_FPS_MAX;
        return "";
    }

    Json::Value@ MaxFpsState(CSystemConfig@ cfg) {
        auto state = Json::Object();
        state["maxFps"] = int(cfg.Display.MaxFps);
        state["uncapped"] = cfg.Display.MaxFps == 0;
        auto vp = GetApp().Viewport;
        if (vp !is null) state["averageFps"] = Math::Round(vp.AverageFps * 10.0) / 10.0;
        return state;
    }

    Json::Value@ MaxFPS(Json::Value &in input) {
        auto app = GetApp();
        CSystemConfig@ cfg = app is null ? null : app.SystemConfig;
        if (cfg is null || cfg.Display is null) return MakeError("system display config not available", "NOT_AVAILABLE", true);
        if (!input.HasKey("fps")) {
            auto output = MaxFpsState(cfg);
            if (cfg.DisplaySafe !is null) output["safeModeMaxFps"] = int(cfg.DisplaySafe.MaxFps);
            return MakeSuccess(output);
        }
        if (input["fps"].GetType() != Json::Type::Number) return MakeError("fps must be an integer", "INVALID_INPUT");
        int fps = int(input["fps"]);
        string err = MaxFpsInputError(fps);
        if (err.Length > 0) return MakeError(err, "INVALID_INPUT");
        uint before = cfg.Display.MaxFps;
        cfg.Display.MaxFps = uint(fps);
        // averageFps is a running average: let a few frames go by at the new
        // limit so the reading moves toward it.
        int settle = input.HasKey("settleFrames") ? Math::Clamp(int(input["settleFrames"]), 0, 120) : 10;
        for (int i = 0; i < settle; i++) yield();
        auto output = MaxFpsState(cfg);
        output["before"] = int(before);
        output["changed"] = before != cfg.Display.MaxFps;
        output["note"] = "Applies now, for this session; not saved to the game's config file. averageFps is a running average and lags a change.";
        return MakeSuccess(output);
    }
}
