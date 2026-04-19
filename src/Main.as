void Main() {
    TmMcp::InitToolSchemas();
    TmMcp::Start();
}

void OnDestroyed() {
    TmMcp::Shutdown();
}

void OnDisabled() {
    TmMcp::Shutdown();
}
