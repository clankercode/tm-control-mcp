[Setting category="Server" name="Socket Port" description="Local TCP port for JSON control requests. Restart or reload the plugin after changing."]
int S_TmMcpPort = 30006;

[Setting category="Server" name="Socket Host" description="Local TCP host for JSON control requests. Use 127.0.0.1 under Wine/Proton unless you specifically need localhost name resolution."]
string S_TmMcpHost = "127.0.0.1";

[Setting category="Server" name="Startup Delay (ms)" description="Delay server socket startup after plugin load. This helps isolate Openplanet startup crashes from socket listener startup."]
int S_TmMcpStartupDelayMs = 100;

[Setting category="Server" name="Trace Requests" description="Log request and response payloads to Openplanet.log."]
bool S_TmMcpTraceRequests = false;

[Setting category="Server" name="Enable Socket" description="When false, skip the TCP listener entirely. Use for in-process-only consumers (e.g. tm-agent). Tools remain callable via import. Requires plugin reload."]
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

    void Start() {
        if (g_running) return;
        g_running = true;
        if (!S_TmMcpEnableSocket) {
            trace("TM Control MCP socket disabled (in-process mode); tools still callable via import");
            return;
        }
        g_starting = true;
        trace("TM Control MCP startup requested; socket delay " + S_TmMcpStartupDelayMs + " ms");
        startnew(CoroutineFunc(StartServerAfterDelay));
    }

    void Shutdown() {
        g_running = false;
        g_listening = false;
        g_starting = false;
        if (g_socket !is null) {
            try {
                g_socket.Close();
            } catch {}
            @g_socket = null;
        }
        CleanupAdHocManialink();
    }

    void StartServerAfterDelay() {
        int delayMs = Math::Max(0, S_TmMcpStartupDelayMs);
        uint startAt = Time::Now;
        while (g_running && Time::Now - startAt < uint(delayMs)) {
            yield();
        }
        if (!g_running) return;

        g_starting = false;
        trace("TM Control MCP starting socket loop after delay");
        ServerLoop();
    }

    void ServerLoop() {
        while (g_running) {
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
            trace("TM Control MCP listening on " + S_TmMcpHost + ":" + S_TmMcpPort);
        } else {
            error("TM Control MCP failed to listen on " + S_TmMcpHost + ":" + S_TmMcpPort);
        }
        return g_listening;
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
