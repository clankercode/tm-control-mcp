#if DEV
namespace TmMcp {
    // Pure fixtures exercised by the diagnostic endpoint in dev builds. No
    // invalid ManiaScript is injected and no map/editor state is mutated.
    Json::Value RunManiaScriptDiagnosticsTests() {
        array<string> messages = {
            "The maptype has crashed. Do you want to restart it?\nYou may cancel to check the error logs.\nUse Shift+Scroll Lock to restart at any time.",
            "Script compilation failed.",
            "The script has crashed.",
            "Do you want to save changes?",
            "Do you want to overwrite this maptype script?",
            ""
        };
        array<bool> expected = {true, true, true, false, false, false};
        Json::Value results = Json::Array();
        bool passed = true;
        for (uint i = 0; i < messages.Length; i++) {
            bool actual = IsManiaScriptCrashMessage(messages[i]);
            Json::Value row = Json::Object();
            row["message"] = messages[i];
            row["actual"] = actual;
            row["expected"] = expected[i];
            row["passed"] = actual == expected[i];
            passed = passed && actual == expected[i];
            results.Add(row);
        }
        Json::Value output = Json::Object();
        output["passed"] = passed;
        output["count"] = int(messages.Length);
        output["results"] = results;
        return output;
    }
}
#endif
