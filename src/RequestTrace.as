// Request/response payload trace — plugin-storage file, not Openplanet.log.
// Openplanet.log stays short: one line with route/tool + byte counts.

const uint TM_MCP_TRACE_ROTATE_BYTES = 2000000;

string TmMcpRequestTracePath() {
    return IO::FromStorageFolder("request-trace.log");
}

string TmMcpRequestTracePrevPath() {
    return IO::FromStorageFolder("request-trace.prev.log");
}

string TmMcpTraceOneLine(const string &in raw) {
    string s = raw.Replace("\r\n", "\\n").Replace("\n", "\\n").Replace("\r", "\\n");
    if (s.Length > 16000) {
        return s.SubStr(0, 16000) + "...[" + s.Length + " bytes]";
    }
    return s;
}

void TmMcpRotateRequestTraceIfNeeded(const string &in path) {
    if (!IO::FileExists(path)) return;
    if (IO::FileSize(path) < TM_MCP_TRACE_ROTATE_BYTES) return;
    string prev = TmMcpRequestTracePrevPath();
    try {
        if (IO::FileExists(prev)) IO::Delete(prev);
        IO::Move(path, prev);
    } catch {}
}

void TmMcpAppendRequestTrace(const string &in kind, const string &in payload) {
    string path = TmMcpRequestTracePath();
    try {
        TmMcpRotateRequestTraceIfNeeded(path);
        IO::File f(path, IO::FileMode::Append);
        f.WriteLine("" + Time::Stamp + " " + kind + " " + TmMcpTraceOneLine(payload));
        f.Close();
    } catch {
        warn("TM Control MCP failed to append request trace: " + getExceptionInfo());
    }
}

void TmMcpTraceExchange(const string &in payload, const string &in responseText) {
    if (!S_TmMcpTraceRequests) return;
    TmMcpAppendRequestTrace("request", payload);
    TmMcpAppendRequestTrace("response", responseText);
}
