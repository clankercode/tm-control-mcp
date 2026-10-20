[Setting hidden]
int S_TmMcpPort = 30006;

[Setting hidden]
string S_TmMcpHost = "127.0.0.1";

[Setting hidden]
int S_TmMcpStartupDelayMs = 100;

[Setting hidden]
bool S_TmMcpTraceRequests = false;

[Setting hidden]
bool S_TmMcpEnableSocket = true;

namespace TmMcp {
    const uint MAX_ACTIVE_CLIENTS = 8;
    const uint CLIENT_READ_TIMEOUT_MS = 10000;
    const uint CLIENT_MAX_REQUEST_BYTES = 16 * 1024 * 1024;
    const uint CLIENT_READ_CHUNK_BYTES = 1024;

    Net::Socket@ g_socket = null;
    bool g_running = false;
    bool g_listening = false;
    bool g_starting = false;
    uint g_activeClients = 0;
    string g_boundHost = "";
    int g_boundPort = 0;

    void Start() {
        if (g_running) return;
        g_running = true;
        g_starting = S_TmMcpEnableSocket;
        trace("TM Control MCP startup requested; socket delay " + S_TmMcpStartupDelayMs + " ms; enable=" + (S_TmMcpEnableSocket ? "true" : "false"));
        startnew(CoroutineFunc(StartServerAfterDelay));
    }

    void Shutdown() {
        StopPackUpdates();
        g_running = false;
        g_starting = false;
        CloseListener();
        CleanupAdHocManialink();
    }

    void CloseListener() {
        g_listening = false;
        g_boundHost = "";
        g_boundPort = 0;
        if (g_socket !is null) {
            try {
                g_socket.Close();
            } catch {}
            @g_socket = null;
        }
    }

    void StartServerAfterDelay() {
        int delayMs = Math::Max(0, S_TmMcpStartupDelayMs);
        uint startAt = Time::Now;
        while (g_running && Time::Now - startAt < uint(delayMs)) {
            yield();
        }
        if (!g_running) return;

        g_starting = false;
        if (!S_TmMcpEnableSocket) {
            trace("TM Control MCP socket disabled (in-process mode); tools still callable via import");
        } else {
            trace("TM Control MCP starting socket loop after delay");
        }
        ServerLoop();
    }

    void ServerLoop() {
        while (g_running) {
            if (!S_TmMcpEnableSocket) {
                if (g_listening) {
                    trace("TM Control MCP socket disabled; closing listener");
                    CloseListener();
                }
                g_starting = false;
                yield();
                continue;
            }

            if (g_listening && (g_boundHost != S_TmMcpHost || g_boundPort != S_TmMcpPort)) {
                trace("TM Control MCP host/port changed; rebinding listener");
                CloseListener();
            }

            if (!EnsureListening()) {
                sleep(1000);
                continue;
            }

            yield();

            Net::Socket@ client = null;
            try {
                @client = g_socket.Accept();
            } catch {
                warn("TM Control MCP accept failed: " + getExceptionInfo());
                g_listening = false;
                sleep(1000);
                continue;
            }
            if (client !is null) {
                if (g_activeClients >= MAX_ACTIVE_CLIENTS) {
                    warn("TM Control MCP rejecting client; too many active clients: " + g_activeClients);
                    CloseClient(client);
                } else {
                    startnew(CoroutineFuncUserdata(HandleClient), client);
                }
            }
        }
        CloseListener();
    }

    bool EnsureListening() {
        if (g_listening && g_socket !is null) return true;

        if (g_socket !is null) {
            try {
                g_socket.Close();
            } catch {}
            @g_socket = null;
        }

        @g_socket = Net::Socket();
        if (g_socket is null) {
            error("TM Control MCP: failed to create socket");
            return false;
        }

        if (S_TmMcpHost != "127.0.0.1") {
            error("TM Control MCP refusing bind host '" + S_TmMcpHost + "'; only 127.0.0.1 is allowed");
            S_TmMcpHost = "127.0.0.1";
            return false;
        }
        if (S_TmMcpPort < 1 || S_TmMcpPort > 65535) {
            error("TM Control MCP refusing invalid port " + S_TmMcpPort);
            return false;
        }

        int prevPort = g_boundPort;
        trace("TM Control MCP attempting listen on 127.0.0.1:" + S_TmMcpPort);
        bool ok = false;
        try {
            ok = g_socket.Listen("127.0.0.1", uint16(S_TmMcpPort));
        } catch {
            error("TM Control MCP listen exception on 127.0.0.1:" + S_TmMcpPort + ": " + getExceptionInfo());
            try { g_socket.Close(); } catch {}
            @g_socket = null;
            g_listening = false;
            return false;
        }
        g_listening = ok;
        if (g_listening) {
            g_boundHost = "127.0.0.1";
            g_boundPort = S_TmMcpPort;
            if (prevPort != 0 && prevPort != S_TmMcpPort) {
                print("TM Control MCP socket port changed " + prevPort + " -> " + S_TmMcpPort);
            }
            trace("TM Control MCP listening on 127.0.0.1:" + S_TmMcpPort);
        } else {
            error("TM Control MCP failed to listen on 127.0.0.1:" + S_TmMcpPort);
            try { g_socket.Close(); } catch {}
            @g_socket = null;
        }
        return g_listening;
    }

    void SetSocketEnabled(bool enabled) {
        if (S_TmMcpEnableSocket == enabled) return;
        S_TmMcpEnableSocket = enabled;
        try { Meta::SaveSettings(); } catch {}
        if (enabled) {
            g_starting = true;
            trace("TM Control MCP socket enable requested");
        } else {
            trace("TM Control MCP socket disable requested");
        }
    }

    void StartSocket() {
        SetSocketEnabled(true);
    }

    void StopSocket() {
        SetSocketEnabled(false);
    }

    bool IsSocketEnabled() {
        return S_TmMcpEnableSocket;
    }

    bool IsSocketListening() {
        return g_listening && g_socket !is null;
    }

    Json::Value@ GetSocketStatus() {
        Json::Value o = Json::Object();
        o["enabled"] = S_TmMcpEnableSocket;
        o["listening"] = IsSocketListening();
        o["starting"] = g_starting && !IsSocketListening();
        o["pluginAlive"] = g_running;
        o["host"] = S_TmMcpHost;
        o["port"] = S_TmMcpPort;
        o["boundHost"] = g_boundHost;
        o["boundPort"] = g_boundPort;
        o["activeClients"] = int(g_activeClients);
        o["traceRequests"] = S_TmMcpTraceRequests;
        o["requestTracePath"] = TmMcpRequestTracePath();
        if (S_TmMcpEnableSocket && IsSocketListening()) o["state"] = "listening";
        else if (S_TmMcpEnableSocket && g_starting) o["state"] = "starting";
        else if (S_TmMcpEnableSocket) o["state"] = "error";
        else o["state"] = "stopped";
        return o;
    }

    void ApplySocketSettings() {
        // ServerLoop notices enable/host/port next frame and binds or closes.
        if (S_TmMcpEnableSocket && !g_running) {
            Start();
        }
    }

    void HandleClient(ref@ userdata) {
        g_activeClients++;
        try {
            HandleClientInner(userdata);
        } catch {
            warn("TM Control MCP client handler failed: " + getExceptionInfo());
        }
        if (g_activeClients > 0) g_activeClients--;
    }

    void HandleClientInner(ref@ userdata) {
        Net::Socket@ client = cast<Net::Socket@>(userdata);
        if (client is null) return;

        string readError;
        string payload = ReadRequestPayload(client, readError);
        Json::Value@ response = readError.Length == 0 ? HandlePayload(payload) : MakeResponse("", "", null, readError);
        string responseText = Json::Write(response);

        if (S_TmMcpTraceRequests) {
            TmMcpTraceExchange(payload, responseText);
        }

        try {
            client.WriteRaw(responseText + "\n");
        } catch {
            warn("TM Control MCP failed to write response: " + getExceptionInfo());
        }

        CloseClient(client);
    }

    void CloseClient(Net::Socket@ client) {
        if (client is null) return;
        try {
            client.Close();
        } catch {}
    }

    string ReadRequestPayload(Net::Socket@ client, string &out error) {
        string payload = "";
        error = "";
        uint started = Time::Now;
        while (Time::Now - started <= CLIENT_READ_TIMEOUT_MS) {
            // ReadRaw has a small native receive buffer. Asking for Available()
            // wholesale silently lost bytes in a 24 KB request (only 3840 read).
            // Bound each read; drain a bounded batch before yielding a frame.
            for (uint batch = 0; batch < 64; batch++) {
                int available = client.Available();
                if (available <= 0) {
                    if (client.IsHungUp()) return payload; // legacy EOF framing
                    break;
                }
                uint amount = Math::Min(uint(available), CLIENT_READ_CHUNK_BYTES);
                string chunk = client.ReadRaw(amount);
                if (chunk.Length == 0) break;
                if (uint(payload.Length) + uint(chunk.Length) > CLIENT_MAX_REQUEST_BYTES) {
                    error = "request exceeds 16 MiB limit";
                    return "";
                }
                payload += chunk;
                if (payload.EndsWith("\n")) return payload;
            }
            // A quiet socket is not an EOF. TCP fragments can arrive after any
            // number of rendered frames; keep waiting for newline or real close.
            yield();
        }
        error = "timed out waiting for complete request (newline or EOF)";
        return "";
    }
}

void OnSettingsChanged() {
    TmMcp::ApplySocketSettings();
}
