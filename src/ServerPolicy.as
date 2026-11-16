namespace TmMcp {
    bool ShouldRestartSocketLoop(bool running, bool hasWorker, bool workerRunning) {
        return running && (!hasWorker || !workerRunning);
    }

    // Rebind only when what was ASKED FOR at bind time is no longer what is wanted.
    // Never compare the bound port with the wanted port: a port.override binds a port
    // other than the setting, and a busy wanted port binds a fallback (wanted+1..), so
    // those differ for the listener's whole life. Comparing them made the loop close and
    // re-listen every pass (2026-11-17: ~30 ms churn, every client connection reset).
    bool ShouldRebindListener(bool listening, const string &in boundHost, const string &in wantedHost,
                              int wantedPortAtBind, int wantedPortNow) {
        if (!listening) return false;
        return boundHost != wantedHost || wantedPortAtBind != wantedPortNow;
    }
}
