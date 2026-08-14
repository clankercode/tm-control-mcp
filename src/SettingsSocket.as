// Socket settings tab + DEV preview window.

string g_SocketHostDraft = "127.0.0.1";
string g_SocketHostError = "";
int g_SocketPortDraft = 30006;
string g_SocketPortError = "";
bool g_SocketDraftReady = false;

void EnsureSocketDrafts() {
    if (g_SocketDraftReady) return;
    g_SocketHostDraft = S_TmMcpHost;
    g_SocketPortDraft = S_TmMcpPort;
    g_SocketDraftReady = true;
}

void SocketSectionLabel(const string &in title) {
    UI::Dummy(vec2(0, 2));
    UI::Text("\\$bbb" + title);
    UI::Dummy(vec2(0, 3));
}

void SocketKv(const string &in key, const string &in value) {
    UI::Text("\\$888" + key);
    UI::SameLine(108);
    UI::Text("\\$eee" + value);
}

void SocketFieldLabel(const string &in label) {
    UI::AlignTextToFramePadding();
    UI::Text("\\$ccc" + label);
    UI::SameLine(108);
}

void SocketStatusBadge(const string &in state) {
    vec4 bg = vec4(0.28, 0.28, 0.30, 1);
    if (state == "listening") bg = vec4(0.14, 0.42, 0.22, 1);
    else if (state == "starting") bg = vec4(0.42, 0.38, 0.10, 1);
    else if (state == "error") bg = vec4(0.52, 0.16, 0.16, 1);

    string label = "Stopped";
    if (state == "listening") label = "Listening";
    else if (state == "starting") label = "Starting";
    else if (state == "error") label = "Error";

    UI::PushStyleColor(UI::Col::Button, bg);
    UI::PushStyleColor(UI::Col::ButtonHovered, bg);
    UI::PushStyleColor(UI::Col::ButtonActive, bg);
    UI::Button(label, vec2(100, 0));
    UI::PopStyleColor(3);
}

void RenderSocketSettingsBody() {
    EnsureSocketDrafts();
    auto st = TmMcp::GetSocketStatus();
    string state = string(st["state"]);
    bool listening = bool(st["listening"]);
    bool enabled = bool(st["enabled"]);
    int clients = int(st["activeClients"]);
    string bindAddr = "127.0.0.1:" + S_TmMcpPort;

    UI::PushItemWidth(220.0);

    SocketSectionLabel("Runtime");

    UI::PushStyleColor(UI::Col::ChildBg, vec4(0.16, 0.16, 0.18, 1));
    UI::PushStyleVar(UI::StyleVar::WindowPadding, vec2(12, 10));
    if (UI::BeginChild("tm-mcp-socket-status", vec2(0, 108), true)) {
        SocketStatusBadge(state);
        UI::SameLine();
        UI::AlignTextToFramePadding();
        UI::Text(listening ? ("\\$ddd" + bindAddr) : "\\$888not bound");

        UI::Dummy(vec2(0, 8));
        SocketKv("Wanted", enabled ? "enabled" : "disabled");
        SocketKv("Clients", "" + clients);
        UI::EndChild();
    }
    UI::PopStyleVar();
    UI::PopStyleColor();

    UI::Dummy(vec2(0, 6));
    UI::TextWrapped("\\$888In-process tools stay available if you stop the socket.");

    SocketSectionLabel("Listen");

    SocketFieldLabel("Host");
    g_SocketHostDraft = UI::InputText("##sock-host", g_SocketHostDraft);
    if (g_SocketHostDraft == "127.0.0.1") {
        g_SocketHostError = "";
        if (S_TmMcpHost != "127.0.0.1") {
            S_TmMcpHost = "127.0.0.1";
            TmMcp::ApplySocketSettings();
        }
    } else if (g_SocketHostDraft.ToLower() == "localhost") {
        g_SocketHostError = "Use 127.0.0.1 — localhost is unreliable under Wine/Proton.";
    } else if (g_SocketHostDraft.Length == 0) {
        g_SocketHostError = "Host cannot be empty. Only 127.0.0.1 is allowed.";
    } else {
        g_SocketHostError = "Only 127.0.0.1 is allowed (localhost-only, no auth).";
    }
    if (g_SocketHostError.Length > 0) {
        UI::TextWrapped("\\$f66" + g_SocketHostError);
    }

    SocketFieldLabel("Port");
    g_SocketPortDraft = UI::InputInt("##sock-port", g_SocketPortDraft);
    if (g_SocketPortDraft < 1 || g_SocketPortDraft > 65535) {
        g_SocketPortError = "Port must be between 1 and 65535.";
    } else if (g_SocketPortDraft == S_TmMcpPort) {
        g_SocketPortError = "";
    } else {
        g_SocketPortError = "";
        UI::SameLine();
        if (UI::Button("Apply port")) {
            S_TmMcpPort = g_SocketPortDraft;
            try { Meta::SaveSettings(); } catch {}
            TmMcp::ApplySocketSettings();
        }
    }
    if (g_SocketPortError.Length > 0) {
        UI::TextWrapped("\\$f66" + g_SocketPortError);
    } else if (g_SocketPortDraft != S_TmMcpPort && g_SocketPortDraft >= 1 && g_SocketPortDraft <= 65535) {
        UI::TextWrapped("\\$888Bound port is still " + S_TmMcpPort + ". Apply to rebind.");
    }

    UI::Dummy(vec2(0, 4));
    SocketFieldLabel("Delay (ms)");
    S_TmMcpStartupDelayMs = Math::Max(0, UI::InputInt("##sock-delay", S_TmMcpStartupDelayMs));
    UI::SameLine();
    UI::TextDisabled("(?)");
    if (UI::IsItemHovered()) {
        UI::SetTooltip("Wait this many milliseconds after plugin start before binding the TCP listener,\nso Openplanet and other plugins can finish loading. Does not apply to live rebind.");
    }
    UI::Dummy(vec2(0, 4));
    S_TmMcpTraceRequests = UI::Checkbox("Trace request payloads to plugin storage", S_TmMcpTraceRequests);
    if (S_TmMcpTraceRequests) {
        UI::TextWrapped("\\$888" + TmMcpRequestTracePath());
    }

    UI::PopItemWidth();
    UI::Dummy(vec2(0, 14));

    if (listening || (enabled && state == "starting")) {
        UI::PushStyleColor(UI::Col::Button, vec4(0.55, 0.18, 0.18, 1));
        UI::PushStyleColor(UI::Col::ButtonHovered, vec4(0.70, 0.24, 0.24, 1));
        UI::PushStyleColor(UI::Col::ButtonActive, vec4(0.45, 0.12, 0.12, 1));
        if (UI::Button("Stop socket", vec2(148, 0))) {
            TmMcp::StopSocket();
        }
        UI::PopStyleColor(3);
    } else {
        UI::PushStyleColor(UI::Col::Button, vec4(0.16, 0.42, 0.24, 1));
        UI::PushStyleColor(UI::Col::ButtonHovered, vec4(0.20, 0.52, 0.30, 1));
        UI::PushStyleColor(UI::Col::ButtonActive, vec4(0.12, 0.34, 0.20, 1));
        if (UI::Button("Start socket", vec2(148, 0))) {
            TmMcp::StartSocket();
        }
        UI::PopStyleColor(3);
    }
}

[SettingsTab name="Socket" icon="Plug" order=0]
void RenderSocketSettingsTab() {
    RenderSocketSettingsBody();
}
