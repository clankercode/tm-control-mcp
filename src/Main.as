void Main() {
    // Cache our own plugin handle BEFORE anything can call into us, so
    // "self" resolution in tools (e.g. ListPluginSettings default plugin)
    // is correct even when invoked in-process from another plugin's context.
    TmMcp::CacheSelfPlugin();
    TmMcp::StartToolCalls();
    TmMcp::InitToolSchemas();
    TmMcp::StartPackUpdates();
    TmMcp::RestoreDisplaySettingOnLifecycle("start");
    TmMcp::Start();
}

void OnDestroyed() {
    TmMcp::ClosePauseOnLifecycle("unload");
    TmMcp::RestoreDisplaySettingOnLifecycle("unload");
    TmMcp::Shutdown();
}

void OnDisabled() {
    TmMcp::ClosePauseOnLifecycle("disable");
    TmMcp::RestoreDisplaySettingOnLifecycle("disable");
    TmMcp::Shutdown();
}
