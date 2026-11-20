void Main() {
    // Cache our own plugin handle BEFORE anything can call into us, so
    // "self" resolution in tools (e.g. ListPluginSettings default plugin)
    // is correct even when invoked in-process from another plugin's context.
    TmMcp::CacheSelfPlugin();
    TmMcp::StartToolCalls();
    TmMcp::InitToolSchemas();
    TmMcp::StartPackUpdates();
    TmMcp::DisplaySettingsOnLifecycle("start");
    TmMcp::Start();
}

void OnDestroyed() {
    TmMcp::DisplaySettingsOnLifecycle("unload");
    TmMcp::Shutdown();
}

void OnDisabled() {
    TmMcp::DisplaySettingsOnLifecycle("disable");
    TmMcp::Shutdown();
}
