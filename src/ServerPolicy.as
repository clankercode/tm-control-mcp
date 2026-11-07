namespace TmMcp {
    bool ShouldRestartSocketLoop(bool running, bool hasWorker, bool workerRunning) {
        return running && (!hasWorker || !workerRunning);
    }
}
