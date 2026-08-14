void Main() {
    // Cache our own plugin handle BEFORE anything can call into us, so
    // "self" resolution in tools (e.g. ListPluginSettings default plugin)
    // is correct even when invoked in-process from another plugin's context.
    TmMcp::CacheSelfPlugin();
    TmMcp::InitToolSchemas();
    TmMcp::Start();
}

void OnDestroyed() {
    TmMcp::Shutdown();
}

void OnDisabled() {
    TmMcp::Shutdown();
}
