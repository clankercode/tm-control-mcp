// Read-only cache view: no requests, disk reads, registry sweep or refresh action.
void RenderPackUpdateRow(const string &in label, const string &in pluginId, const string &in url) {
    auto status = Json::Object();
    TmMcp::AppendPackUpdateStatus(status, pluginId, url);
    UI::Separator();
    UI::Text(label);
    UI::Text("Installed: " + string(status["installedVersion"]) + " | Latest: " + string(status["latestVersion"]));
    UI::Text("Status: " + string(status["updateStatus"]));
    if (bool(status["updateStale"])) UI::Text("Cached version is stale.");
    string error = string(status["updateError"]);
    if (error.Length > 0) UI::TextWrapped(error);
    if (url.Length > 0) UI::TextWrapped(url);
}

[SettingsTab name="Updates" icon="Refresh" order=1]
void RenderUpdatesSettingsTab() {
    UI::TextWrapped("Cached version checks for the bridge and registered tool packs. Successful checks are cached for 6 hours; failures retry after 30 minutes. Updates are not installed automatically.");
    // Local preference only; the worker owns any subsequent network action.
    S_TmMcpCheckUpdates = UI::Checkbox("Check for updates", S_TmMcpCheckUpdates);
    if (!S_TmMcpCheckUpdates) UI::Text("Automatic checks are disabled.");
    auto self = TmMcp::SelfPlugin();
    RenderPackUpdateRow("TM Control MCP", self is null ? "tm-control-mcp" : self.ID, TmMcp::BRIDGE_UPDATE_URL);
    for (uint i = 0; i < TmMcp::g_Packs.Length; i++) {
        auto pack = TmMcp::g_Packs[i];
        RenderPackUpdateRow(pack.packId, pack.pluginId, pack.latestReleaseUrl);
    }
}
