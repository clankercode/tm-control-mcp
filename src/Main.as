void Main() {
    TmMcp::Start();
}

void OnDestroyed() {
    TmMcp::Shutdown();
}

void OnDisabled() {
    TmMcp::Shutdown();
}
