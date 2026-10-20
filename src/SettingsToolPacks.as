// Read-only diagnostic view of the in-process tool-pack registry.

string ToolPackSchemaText(Json::Value@ schema) {
    if (schema is null) return "{}";
    return Json::Write(schema);
}

[SettingsTab name="Tool packs" icon="List" order=2]
void RenderToolPacksSettingsTab() {
    TmMcp::SweepDeadPacks();
    UI::Text("\\$bbbRegistered tool packs");
    UI::TextWrapped("\\$888Diagnostic view only. Packs and schemas are read-only.");
    UI::Dummy(vec2(0, 4));

    if (TmMcp::g_Packs.Length == 0) {
        UI::Text("\\$888No tool packs registered.");
        return;
    }

    for (uint i = 0; i < TmMcp::g_Packs.Length; i++) {
        auto pack = TmMcp::g_Packs[i];
        if (!UI::TreeNode(pack.packId + "  \\$888(" + pack.toolNames.Length + " tools)")) continue;
        UI::Text("\\$888Plugin: \\$ddd" + pack.pluginId);
        for (uint t = 0; t < pack.toolNames.Length; t++) {
            string fullName = pack.packId + "." + pack.toolNames[t];
            if (!UI::TreeNode(fullName)) continue;
            UI::TextWrapped("\\$ccc" + pack.descriptions[t]);
            UI::Text("\\$888Schema");
            UI::PushTextWrapPos();
            UI::Text(ToolPackSchemaText(pack.schemas[t]));
            UI::PopTextWrapPos();
            UI::TreePop();
        }
        UI::TreePop();
    }
}
