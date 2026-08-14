[Setting category="Server" name="Socket Port" description="Local TCP port for JSON control requests. Applied live (listener rebinds)."]
int S_TmMcpPort = 30006;

[Setting category="Server" name="Socket Host" description="Local TCP host for JSON control requests. Use 127.0.0.1 under Wine/Proton unless you specifically need localhost name resolution. Applied live."]
string S_TmMcpHost = "127.0.0.1";

[Setting category="Server" name="Startup Delay (ms)" description="Delay server socket startup after plugin load. This helps isolate Openplanet startup crashes from socket listener startup."]
int S_TmMcpStartupDelayMs = 100;

[Setting category="Server" name="Trace Requests" description="Log request and response payloads to Openplanet.log."]
bool S_TmMcpTraceRequests = false;

// Hidden: toggle via SetSocketEnabled / Settings tab / SetPluginSetting, not the raw checkbox.
[Setting hidden]
bool S_TmMcpEnableSocket = true;

namespace TmMcp {
    const uint MAX_ACTIVE_CLIENTS = 8;
    const uint CLIENT_READ_TIMEOUT_MS = 2000;
    const uint CLIENT_QUIET_FRAMES_AFTER_BYTES = 3;

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

        trace("TM Control MCP attempting listen on " + S_TmMcpHost + ":" + S_TmMcpPort);
        g_listening = g_socket.Listen(S_TmMcpHost, uint16(S_TmMcpPort));
        if (g_listening) {
            g_boundHost = S_TmMcpHost;
            g_boundPort = S_TmMcpPort;
            trace("TM Control MCP listening on " + S_TmMcpHost + ":" + S_TmMcpPort);
        } else {
            error("TM Control MCP failed to listen on " + S_TmMcpHost + ":" + S_TmMcpPort);
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

        string payload = ReadRequestPayload(client);
        Json::Value@ response = HandlePayload(payload);
        string responseText = Json::Write(response);

        if (S_TmMcpTraceRequests) {
            trace("TM Control MCP request: " + payload);
            trace("TM Control MCP response: " + responseText);
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

    string ReadRequestPayload(Net::Socket@ client) {
        string payload = "";
        bool sawBytes = false;
        uint quietFrames = 0;
        uint timeoutAt = Time::Now + CLIENT_READ_TIMEOUT_MS;

        while (Time::Now <= timeoutAt) {
            int available = 0;
            try {
                available = client.Available();
            } catch {
                warn("TM Control MCP failed checking client bytes: " + getExceptionInfo());
                break;
            }
            if (available > 0) {
                payload += client.ReadRaw(available);
                if (payload.EndsWith("\n")) break;
                sawBytes = true;
                quietFrames = 0;
            } else if (sawBytes) {
                quietFrames++;
                if (quietFrames >= CLIENT_QUIET_FRAMES_AFTER_BYTES) break;
            }
            yield();
        }

        return payload;
    }
}

void OnSettingsChanged() {
    TmMcp::ApplySocketSettings();
}

[SettingsTab name="Socket" icon="Plug" order=0]
void RenderSocketSettingsTab() {
    auto st = TmMcp::GetSocketStatus();
    string state = string(st["state"]);
    bool listening = bool(st["listening"]);
    bool enabled = bool(st["enabled"]);

    string color = "888";
    if (state == "listening") color = "6c6";
    else if (state == "starting") color = "cc6";
    else if (state == "error") color = "c66";
    else if (state == "stopped") color = "888";

    UI::Text("\\\\$" + color + "Status: " + state + "\\\\$z");
    UI::Text("Wanted: " + (enabled ? "enabled" : "disabled") + "   Listening: " + (listening ? "yes" : "no"));
    UI::Text("Bind: " + S_TmMcpHost + ":" + S_TmMcpPort);
    if (listening) {
        UI::Text("Bound: " + string(st["boundHost"]) + ":" + int(st["boundPort"]));
    }
    UI::Text("Active clients: " + int(st["activeClients"]));
    UI::TextWrapped("\\\\$aaaIn-process tools stay available when the socket is stopped. Host/port below apply live (no reload).");

    UI::Separator();

    if (listening || (enabled && state == "starting")) {
        if (UI::Button("Stop socket")) {
            TmMcp::StopSocket();
        }
    } else {
        if (UI::Button("Start socket")) {
            TmMcp::StartSocket();
        }
    }
    UI::SameLine();
    if (UI::Button("Apply host/port")) {
        TmMcp::ApplySocketSettings();
    }

    UI::Separator();
    UI::TextDisabled("Host / port / trace are in the Server settings category.");
}
