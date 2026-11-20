// On-screen tool call overlay: a small bottom-left HUD listing the most
// recent tool calls (name, duration, ok/ERR) so a recording of a
// presentation/take shows the actual tool traffic. Rows are recorded in
// ToolCalls.as at the two lifecycle funnels -- admission
// (CallOverlayBegin) and FinishToolCall (CallOverlayFinish) -- which every
// admitted call passes through exactly once: socket requests, in-process
// imports, tool packs, timeouts and bridge shutdown. Pre-admission
// rejections (unknown tool, invalid input, busy) never dispatch a worker
// and are not listed. DEV builds only.

#if DEV
[Setting name="Show tool call overlay" description="Bottom-left HUD listing recent MCP tool calls: name, duration, ok/ERR code."]
bool S_TmMcpShowCallOverlay = true;

[Setting name="Tool call overlay: hide tools" description="Comma-separated tool names that get no overlay row (still counted in the header as hidden). Default hides the presentation director's own polling."]
string S_TmMcpCallOverlayHide = "Present.Events,Present.Heartbeat";

// Drawn from Render() (SettingsSocket.as), not RenderInterface: Present hides the
// Openplanet overlay during takes, which suppresses RenderInterface, and the
// overlay must appear in recordings.
void RenderCallOverlayIfEnabled() {
    if (!S_TmMcpShowCallOverlay) return;
    TmMcp::RenderCallOverlay();
}
#endif

namespace TmMcp {
    const uint CALL_OVERLAY_ROWS = 8;

    class CallOverlayRow {
        uint64 id;       // ToolCallRegistry lease id; matches FinishToolCall
        string name;
        uint64 start;
        uint64 end = 0;  // 0 while the worker is still running
        bool ok = true;
        string code;     // error code when !ok ("" when the tool set none)
        string line;     // prebuilt render text; running rows refresh throttled
        uint64 lineAt;   // Time::Now of the last line rebuild
    }

    // Oldest first, capped at CALL_OVERLAY_ROWS. One small object per tool
    // call; the render path only reads it (plus a throttled running-ms
    // refresh), so the bridge hot paths stay allocation-free per frame.
    array<CallOverlayRow@> g_callOverlayRows;
    uint64 g_callOverlayCalls = 0;  // admitted calls this dispatch session
    uint64 g_callOverlayHidden = 0; // of those, calls on the hide list (no row)
    string g_callOverlayHeader = "";

    // Parsed S_TmMcpCallOverlayHide, re-split only when the setting changes.
    string g_callOverlayHideRaw = "\x01";  // never equals a real setting value
    array<string> g_callOverlayHideNames;

    bool CallOverlayHidden(const string &in name) {
#if DEV
        if (S_TmMcpCallOverlayHide != g_callOverlayHideRaw) {
            g_callOverlayHideRaw = S_TmMcpCallOverlayHide;
            g_callOverlayHideNames = CallOverlayParseHideList(g_callOverlayHideRaw);
        }
        return g_callOverlayHideNames.Find(name) >= 0;
#else
        return false;
#endif
    }

    void CallOverlayUpdateHeader() {
        g_callOverlayHeader = CallOverlayHeaderText(g_callOverlayCalls, g_callOverlayHidden);
    }

    void CallOverlayPushRow(CallOverlayRow@ row) {
        // Evict the oldest finished row first: a burst of overlapping calls
        // (MAX_TOOL_CALLS is 32) must not push a still-running one out of view.
        if (g_callOverlayRows.Length >= CALL_OVERLAY_ROWS) {
            for (uint i = 0; i < g_callOverlayRows.Length; i++) {
                if (g_callOverlayRows[i].end > 0) { g_callOverlayRows.RemoveAt(i); break; }
            }
            if (g_callOverlayRows.Length >= CALL_OVERLAY_ROWS) g_callOverlayRows.RemoveAt(0);
        }
        g_callOverlayRows.InsertLast(row);
    }

    // Called in CallToolExpected right after a call is admitted.
    void CallOverlayBegin(uint64 id, const string &in name) {
        g_callOverlayCalls++;
        bool hidden = CallOverlayHidden(name);
        if (hidden) g_callOverlayHidden++;
        CallOverlayUpdateHeader();
        if (hidden) return;
        auto row = CallOverlayRow();
        row.id = id;
        row.name = name;
        row.start = Time::Now;
        row.line = name + " ...";
        row.lineAt = row.start;
        CallOverlayPushRow(row);
    }

    // Called from FinishToolCall, the single funnel every admitted call
    // exits through (completion, exception, timeout sweep, shutdown).
    void CallOverlayFinish(uint64 id, const string &in name, uint64 start, Json::Value@ result) {
        bool ok = result !is null && result.HasKey("success") && bool(result["success"]);
        string code = "";
        if (!ok && result !is null && result.HasKey("code") && result["code"].GetType() == Json::Type::String)
            code = string(result["code"]);
        uint64 end = Time::Now;
        CallOverlayRow@ row = null;
        for (int i = int(g_callOverlayRows.Length) - 1; i >= 0; i--) {
            if (g_callOverlayRows[i].id == id && g_callOverlayRows[i].end == 0) {
                @row = g_callOverlayRows[i];
                break;
            }
        }
        if (row is null) {
            // Hidden calls never had a row: do not recreate one.
            if (CallOverlayHidden(name)) return;
            // Evicted while still running (8+ newer calls since it started).
            // Recreate it so the outcome is still shown.
            row = CallOverlayRow();
            row.id = id;
            row.name = name;
            row.start = start;
            CallOverlayPushRow(row);
        }
        row.ok = ok;
        row.code = code;
        row.end = end;
        row.line = name + " " + (end - start) + "ms " + (ok ? "ok" : (code.Length > 0 ? "ERR:" + code : "ERR"));
        row.lineAt = end;
    }

    void RenderCallOverlay() {
        if (g_callOverlayRows.Length == 0) return;
        UI::DrawList@ dl = UI::GetForegroundDrawList();
        float fontH = UI::GetFontSize();
        float lineH = fontH + 3.0;
        float pad = 6.0;

        float longest = UI::MeasureString(g_callOverlayHeader).x;
        for (uint i = 0; i < g_callOverlayRows.Length; i++) {
            CallOverlayRow@ row = g_callOverlayRows[i];
            // Live duration for running rows, throttled to ~4 Hz so steady
            // state is plain draws with no per-frame string building.
            if (row.end == 0 && Time::Now - row.lineAt >= 250) {
                row.line = row.name + " " + (Time::Now - row.start) + "ms ...";
                row.lineAt = Time::Now;
            }
            vec2 measured = UI::MeasureString(row.line);  // exact drawn width (user report 2026-11-20)
            if (measured.x > longest) longest = measured.x;
        }

        float x0 = 14.0;
        float width = longest + pad * 2.0;
        float blockH = lineH * float(g_callOverlayRows.Length + 1) + pad;
        float y0 = float(Display::GetHeight()) - 16.0 - blockH;

        dl.AddRectFilled(vec4(x0 - pad, y0, x0 + width, y0 + blockH), vec4(0.0, 0.0, 0.0, 0.45));
        dl.AddText(vec2(x0, y0 + pad * 0.5), vec4(0.62, 0.62, 0.66, 0.9), g_callOverlayHeader);
        for (uint i = 0; i < g_callOverlayRows.Length; i++) {
            CallOverlayRow@ row = g_callOverlayRows[i];
            float alpha = 1.0;
            if (row.end > 0) {
                // Finished rows fade to a floor once stale, so an idle
                // screen does not read as live traffic.
                int age = int(Time::Now - row.end);
                if (age > 10000) {
                    alpha = 1.0 - float(age - 10000) / 20000.0;
                    if (alpha < 0.35) alpha = 0.35;
                }
            }
            vec4 color = vec4(0.65, 0.87, 0.65, 0.92 * alpha);
            if (row.end == 0) color = vec4(0.95, 0.85, 0.45, 0.95);
            else if (!row.ok) color = vec4(0.96, 0.42, 0.42, 0.95 * alpha);
            dl.AddText(vec2(x0, y0 + pad * 0.5 + lineH * float(i + 1)), color, row.line);
        }
    }
}
