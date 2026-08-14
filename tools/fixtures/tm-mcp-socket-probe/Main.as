// In-process export probe for socket lifecycle. Writes PluginStorage JSON.

void Main() {
    Json::Value report = Json::Object();
    Json::Value steps = Json::Array();
    report["ok"] = false;

    try {
        Json::Value before = TmMcp::GetSocketStatus();
        before["step"] = "before";
        before["isEnabledFn"] = TmMcp::IsSocketEnabled();
        before["isListeningFn"] = TmMcp::IsSocketListening();
        steps.Add(before);

        TmMcp::SetSocketEnabled(false);
        uint stopAt = Time::Now;
        while (Time::Now - stopAt < 1500 && TmMcp::IsSocketListening()) {
            yield();
        }
        Json::Value stopped = TmMcp::GetSocketStatus();
        stopped["step"] = "afterSetFalse";
        stopped["isEnabledFn"] = TmMcp::IsSocketEnabled();
        stopped["isListeningFn"] = TmMcp::IsSocketListening();
        steps.Add(stopped);

        TmMcp::StopSocket();
        TmMcp::StartSocket();
        uint startAt = Time::Now;
        while (Time::Now - startAt < 2000 && !TmMcp::IsSocketListening()) {
            yield();
        }
        Json::Value started = TmMcp::GetSocketStatus();
        started["step"] = "afterStart";
        started["isEnabledFn"] = TmMcp::IsSocketEnabled();
        started["isListeningFn"] = TmMcp::IsSocketListening();
        steps.Add(started);

        bool stopOk = bool(stopped["enabled"]) == false && !bool(stopped["isListeningFn"]);
        bool startOk = bool(started["enabled"]) == true && bool(started["isListeningFn"]);
        report["ok"] = stopOk && startOk;
        report["stopOk"] = stopOk;
        report["startOk"] = startOk;
    } catch {
        report["error"] = getExceptionInfo();
    }

    report["steps"] = steps;
    string path = IO::FromStorageFolder("socket-lifecycle.json");
    Json::ToFile(path, report);
    print("TMCT-SOCK probe wrote " + path + " ok=" + (bool(report["ok"]) ? "true" : "false"));
}
