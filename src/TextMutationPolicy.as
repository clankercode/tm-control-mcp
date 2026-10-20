namespace TmMcp {
    // Keep replacement planning independent of live nods and bounded before writes.
    const uint TEXT_PATCH_MAX = 262144;
    const uint TEXT_PATCH_MATCH_MAX = 4096;
    const uint TEXT_PATCH_PART_MAX = 65536;

    class TextPatchPlan {
        string error;
        string text;
        uint matched = 0;
        bool changed = false;
    }

    TextPatchPlan@ PlanTextPatch(const string &in source, const string &in find,
                                 const string &in replacement, bool all) {
        auto plan = TextPatchPlan();
        if (find.Length == 0) { plan.error = "EMPTY_FIND"; return plan; }
        if (uint(source.Length) > TEXT_PATCH_MAX || uint(find.Length) > TEXT_PATCH_PART_MAX
            || uint(replacement.Length) > TEXT_PATCH_PART_MAX) {
            plan.error = "TEXT_TOO_LARGE"; return plan;
        }
        uint pos = 0;
        while (pos < uint(source.Length)) {
            int rel = source.SubStr(pos).IndexOf(find);
            if (rel < 0) break;
            uint at = pos + uint(rel);
            if (uint(plan.text.Length) + uint(rel) + uint(replacement.Length) > TEXT_PATCH_MAX) {
                plan.error = "TEXT_TOO_LARGE"; return plan;
            }
            plan.text += source.SubStr(pos, uint(rel)) + replacement;
            plan.matched++;
            if (all && plan.matched > TEXT_PATCH_MATCH_MAX) { plan.error = "TOO_MANY_MATCHES"; return plan; }
            pos = at + uint(find.Length);
            if (!all) break;
        }
        if (uint(plan.text.Length) + uint(source.Length) - pos > TEXT_PATCH_MAX) {
            plan.error = "TEXT_TOO_LARGE"; return plan;
        }
        plan.text += source.SubStr(pos);
        plan.changed = plan.text != source;
        return plan;
    }

    bool IsUserEditorScriptPath(const string &in path) {
        if (!path.StartsWith("Scripts/EditorPlugins/") || path.Length > 512
            || path.Length <= 22 || path.IndexOf("..") >= 0 || path.IndexOf(":") >= 0
            || path.IndexOf("\\") >= 0 || path.IndexOf("//") >= 0) return false;
        for (uint i = 0; i < uint(path.Length); i++) if (path[i] < 32 || path[i] == 127) return false;
        return path.Length >= 11 && path.SubStr(path.Length - 11) == ".Script.txt";
    }
}
