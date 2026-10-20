#if DEV
namespace TmMcp {
    // Observe availability only. Never request, access, decode, or transmit credentials.
    Json::Value@ RunDevNativeAuthProbe(Json::Value &in input) {
        if (input.GetType() != Json::Type::Object) return MakeError("Input must be an object", "BAD_INPUT");
        if (input.HasKey("mode") && (input["mode"].GetType() != Json::Type::String
            || string(input["mode"]) != "status")) return MakeError("Only status is supported", "BAD_INPUT");
        auto keys = input.GetKeys();
        for (uint i = 0; i < keys.Length; i++) if (keys[i] != "mode") return MakeError("Unknown option", "BAD_INPUT");
        auto output = Json::Object();
        auto app = cast<CTrackMania>(GetApp());
        auto api = app is null ? null : app.ManiaPlanetScriptAPI;
        output["apiAvailable"] = api !is null;
        bool userPresent = app !is null && app.MenuManager !is null
            && app.MenuManager.ManialinkScriptHandlerMenus !is null
            && app.MenuManager.ManialinkScriptHandlerMenus.LocalUser !is null;
        output["menuLocalUserPresent"] = userPresent;
        if (api !is null) {
            output["legacyResponseReceived"] = api.Authentication_GetTokenResponseReceived;
            output["legacyErrorPresent"] = api.Authentication_ErrorCode != 0;
            output["taskCount"] = api.MasterServer_MSTaskResults.Length;
        }
        output["credentialValuesRead"] = false;
        return MakeSuccess(output);
    }
}
#endif
