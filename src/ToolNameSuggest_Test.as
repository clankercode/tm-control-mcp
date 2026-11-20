// Pins for the unknown-tool suggestions in ToolNameSuggest.as. Openplanet's
// [Test] runner calls these; tests/test_tool_name_suggest.py runs the same
// bodies in stock AngelScript. Cases are the names agents guessed on 2026-11-15.
namespace Tests {
    array<string> ToolNameSuggest_Known() {
        array<string> known = {
            "GetMode", "ControlPlugin", "GetPlugin", "ListPlugins", "ListPluginSettings",
            "GetPluginSetting", "SetPluginSetting", "ControlEditorScriptPlugins", "ControlCamera",
            "ListToolPacks", "TakeScreenshot", "GetMenuFrameTree", "ClickClassicMenuControl",
            "JoinServer", "RespondDialog", "GetDialog", "CarControl.Status", "CarControl.SetInput"
        };
        return known;
    }

    string ToolNameSuggest_First(const string &in asked) {
        auto picks = TmMcp::SuggestToolNames(asked, ToolNameSuggest_Known());
        return picks.Length > 0 ? picks[0] : "";
    }

    [Test]
    void ToolNameSuggest_ReloadVerbMeansControl(Tests::Context@ ctx) {
        ctx.AssertSame(ToolNameSuggest_First("ReloadPlugin"), "ControlPlugin", "ReloadPlugin");
        ctx.AssertSame(ToolNameSuggest_First("ReloadPlugins"), "ControlPlugin", "ReloadPlugins");
    }

    [Test]
    void ToolNameSuggest_PackToolByWords(Tests::Context@ ctx) {
        ctx.AssertSame(ToolNameSuggest_First("CarControl.GetStatus"), "CarControl.Status", "pack status");
        ctx.AssertSame(ToolNameSuggest_First("GetStatus"), "CarControl.Status", "unprefixed pack tool");
    }

    [Test]
    void ToolNameSuggest_CaseAndTypos(Tests::Context@ ctx) {
        ctx.AssertSame(ToolNameSuggest_First("getmode"), "GetMode", "case");
        ctx.AssertSame(ToolNameSuggest_First("GetMdoe"), "GetMode", "transposed letters");
        ctx.AssertSame(ToolNameSuggest_First("ListPacks"), "ListToolPacks", "near miss");
    }

    [Test]
    void ToolNameSuggest_BoundedAndQuiet(Tests::Context@ ctx) {
        ctx.AssertTrue(TmMcp::SuggestToolNames("Xyzzy", ToolNameSuggest_Known()).Length == 0, "nothing close");
        ctx.AssertTrue(TmMcp::SuggestToolNames("", ToolNameSuggest_Known()).Length == 0, "empty");
        ctx.AssertTrue(TmMcp::SuggestToolNames("Plugin", ToolNameSuggest_Known()).Length == TmMcp::UNKNOWN_TOOL_MAX_SUGGESTIONS, "capped");
        string huge = "GetMode";
        for (uint i = 0; i < 4; i++) huge += huge;
        ctx.AssertTrue(TmMcp::SuggestToolNames(huge, ToolNameSuggest_Known()).Length == 0, "long input not matched");
    }

    [Test]
    void ToolNameSuggest_EchoOnlyNameShaped(Tests::Context@ ctx) {
        ctx.AssertTrue(TmMcp::IsEchoableToolName("CarControl.GetStatus"), "pack name");
        ctx.AssertTrue(TmMcp::IsEchoableToolName("tm-mcp-pack-epp.Place_1"), "dash, underscore, digit");
        ctx.AssertFalse(TmMcp::IsEchoableToolName(""), "empty");
        ctx.AssertFalse(TmMcp::IsEchoableToolName("Get Mode"), "space");
        ctx.AssertFalse(TmMcp::IsEchoableToolName("GetMode\nforged"), "newline");
        string longName = "A";
        for (uint i = 0; i < 6; i++) longName += longName;
        ctx.AssertTrue(TmMcp::IsEchoableToolName(longName), "64 chars");
        ctx.AssertFalse(TmMcp::IsEchoableToolName(longName + "A"), "over 64 chars");
    }

    [Test]
    void ToolNameSuggest_Words(Tests::Context@ ctx) {
        auto words = TmMcp::ToolNameWords("GetUILayers");
        ctx.AssertTrue(words.Length == 3, "three words");
        if (words.Length == 3) {
            ctx.AssertSame(words[0], "get", "get");
            ctx.AssertSame(words[1], "ui", "acronym");
            ctx.AssertSame(words[2], "layer", "plural");
        }
        ctx.AssertTrue(TmMcp::ToolNameEditDistance("getmdoe", "getmode") == 2, "distance");
    }
}
