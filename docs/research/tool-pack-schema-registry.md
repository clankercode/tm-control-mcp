# Runtime schema registry for pack tools

Research for [#8](https://github.com/clankercode/tm-control-mcp/issues/8) (parent [#6](https://github.com/clankercode/tm-control-mcp/issues/6), feature [#5](https://github.com/clankercode/tm-control-mcp/issues/5)).
Not an implementation. Findings are from current `master` sources only.

## Question

Can pack tools join `ToolInputValidation` **after** startup `InitToolSchemas()`, and be removed on unregister, without breaking builtin validation?

Need facts on:

- Current `InitToolSchemas` / registry shape
- Whether schemas can be added/removed at runtime
- What `GetToolList` / `tools` route should return for prefixed names
- Failure mode if a pack schema is invalid JSON

## Verdict

| Question | Answer today |
|---|---|
| Can a pack join the validator after `InitToolSchemas`? | **Not with existing APIs.** The registry is filled once at plugin start from `GetToolList()` and then never mutated. Adding after startup requires new insert/remove helpers (or a rebuild that still includes builtins). |
| Can a pack be removed on unregister without breaking builtins? | **Not with existing APIs.** There is no remove path. Re-calling `InitToolSchemas()` would wipe **all** schemas first (including builtins) and only restore whatever `GetToolList()` currently returns. |
| What must `GetToolList` return for prefixed names? | Same Anthropic object as builtins: `{name, description, input_schema}`. `name` must be the public MCP name `packId.FuncName`. Builtins stay unprefixed (`GetMode`). An optional `pack` field is still undecided. |
| Failure mode for bad pack schema JSON | Unguarded `Json::Parse` **throws**. If that throw happens inside `GetToolList()` / `MakeTool` during `InitToolSchemas`, the registry has already been cleared — **builtin validation is emptied**. If parse is guarded and the value is null / non-object, that tool is **silently skipped** and later calls skip validation. |

Pack registration does not exist in this repo yet (`RegisterToolPack` / `UnregisterToolPack` / `ToolPackBuilder` are glossary + issue text only). The rest of this note is what the current validator / list / dispatch actually do, and what that implies for the pack design.

---

## 1. Current registry shape

Source: [`src/ToolInputValidation.as`](../../src/ToolInputValidation.as).

The validator is **not** a dictionary. It is two parallel arrays, documented as a workaround for AngelScript reserved `set`/`get` keywords:

```12:21:src/ToolInputValidation.as
    // Flat parallel arrays instead of dictionary (avoids 'set'/'get' reserved keyword issue).
    array<string>       g_schemaToolNames;
    array<ToolSchema@>  g_schemaRecords;

    int FindSchema(const string &in toolName) {
        for (uint i = 0; i < g_schemaToolNames.Length; i++) {
            if (g_schemaToolNames[i] == toolName) return int(i);
        }
        return -1;
    }
```

Each `ToolSchema` holds only **top-level** facts parsed from `input_schema`:

- `toolName`
- `allowedKeys` + parallel `allowedKeyTypes` (one type string per key)
- `requiredKeys`

`FindSchema` is a linear exact-string scan. First match wins. There is no uniqueness check on insert.

### What `InitToolSchemas` does

Called **once** from plugin `Main()`, after `CacheSelfPlugin()` and before `Start()`:

```1:8:src/Main.as
void Main() {
    // Cache our own plugin handle BEFORE anything can call into us, so
    // "self" resolution in tools (e.g. ListPluginSettings default plugin)
    // is correct even when invoked in-process from another plugin's context.
    TmMcp::CacheSelfPlugin();
    TmMcp::InitToolSchemas();
    TmMcp::Start();
}
```

The function itself:

1. `g_schemaToolNames.Resize(0)` and `g_schemaRecords.Resize(0)` — **full wipe**.
2. `Json::Value@ tools = GetToolList()`.
3. If `tools` is null or not an array, **return** (registry stays empty).
4. For each entry: skip unless it has `name` and `input_schema`; skip unless `input_schema` is a JSON object.
5. Parse `properties` keys + `type` (string only; union arrays leave the type string empty).
6. Parse `required` string elements.
7. `InsertLast` into both arrays.
8. Trace how many schemas loaded.

```23:81:src/ToolInputValidation.as
    // Called once at plugin startup. Parses GetToolList() schemas into the registry.
    void InitToolSchemas() {
        g_schemaToolNames.Resize(0);
        g_schemaRecords.Resize(0);

        Json::Value@ tools = GetToolList();
        if (tools is null || tools.GetType() != Json::Type::Array) return;
        // ... parse each entry; continue on missing name / input_schema / non-object ...
        trace("TM Control MCP: InitToolSchemas loaded " + g_schemaToolNames.Length + " tool schemas");
    }
```

There is **no** `RegisterSchema`, `UnregisterSchema`, `RemoveSchema`, or pack-aware rebuild. The only mutation after startup would be another call to `InitToolSchemas()`.

### What `ValidateToolInput` does

```86:91:src/ToolInputValidation.as
    string ValidateToolInput(const string &in toolName, Json::Value@ input) {
        int idx = FindSchema(toolName);
        if (idx < 0) {
            // Unknown tool — let dispatch emit the unknown-tool error.
            return "";
        }
```

Unknown name ⇒ empty string (success). The comment is explicit: validation is **opt-in by presence in the registry**. A pack tool that is listed in `GetToolList` but never inserted into `g_schema*` is **not validated at all**.

When a schema **is** present, checks are:

1. Every input key must be in `allowedKeys` (unknown → `"unknown parameter 'k' (allowed: …)"`).
2. Every `requiredKeys` entry must be present.
3. Provided keys with a non-empty type string must match (`string` / `integer`|`number` / `boolean` / `object` / `array`). Unknown type strings pass through. Union types (`["string","integer"]`) leave `typeStr` empty and skip the type check while still enforcing unknown/required keys ([`ToolInputValidation.as` 58–60](../../src/ToolInputValidation.as)).

`additionalProperties` is present on almost every builtin schema string but is **never read**. The validator always rejects unknown top-level keys.

The socket `call` path runs validation **before** dispatch:

```75:82:src/Protocol.as
        string validationErr = ValidateToolInput(tool, input);
        if (validationErr.Length > 0) {
            return MakeResponse(id, route, null, "invalid input for " + tool + ": " + validationErr);
        }

        Json::Value@ result = CallTool(tool, input);
        if (result is null) {
            return MakeResponse(id, route, null, "unknown tool: " + tool);
```

The Python client mirrors this (`tools/call.py` `validate_input`, comment: “mirrors AS ValidateToolInput”; unit tests in `tests/test_call_wait.py`).

---

## 2. Can pack tools join after `InitToolSchemas`?

**Today: no.** Two independent surfaces both need a pack to become visible:

| Surface | When populated | Pack-aware today? |
|---|---|---|
| Validation registry `g_schema*` | Once in `Main()` via `InitToolSchemas()` | No. Only walks whatever `GetToolList()` returned at that instant. |
| Discovery list `GetToolList()` | Rebuilt on every `tools` request and every `InitToolSchemas` | No. Hardcoded `MakeTool("GetMode", …)` … `MakeTool("GetResult", …)` then `return tools`. |

`GetToolList` ends with builtins only:

```1138:1148:src/McpTools.as
        tools.Add(MakeTool("GetResult", "Poll for async tool result. ...", '{...}'));
        return tools;
    }

    Json::Value MakeTool(const string &in name, const string &in description, const string &in inputSchemaJson) {
        Json::Value tool = Json::Object();
        tool["name"] = name;
        tool["description"] = description;
        tool["input_schema"] = Json::Parse(inputSchemaJson);
        return tool;
    }
```

The `tools` route is a straight passthrough of that array:

```44:46:src/Protocol.as
        if (route == "tools") {
            return MakeResponse(id, route, GetToolList(), "");
        }
```

In-process consumers import the same function (`TmMcp_Export.as` 22–26: Anthropic `{name, description, input_schema}`).

### What would actually work (design implication, not implemented)

Two viable shapes, both compatible with the current parallel-array registry:

**A. Incremental insert/remove (safer for builtins).**

- `RegisterToolSchema(name, schemaObject)` → parse one object the same way `InitToolSchemas` parses one entry, `InsertLast` on both arrays. Do **not** call `InitToolSchemas`.
- `UnregisterToolSchema(name)` / `UnregisterToolSchemasByPrefix("packId.")` → `FindSchema` then remove the same index from both arrays.
- Builtin rows stay untouched.

This matches issue #5’s note that “Validation already generic (ToolInputValidation.as) — packs just supply schemas.”

**B. Rebuild from a pack-aware `GetToolList`.**

- Change `GetToolList()` to append currently-registered pack tools after the builtin `MakeTool` list.
- On register/unregister, call `InitToolSchemas()` again.

This keeps one parser. It is **unsafe** unless `GetToolList` cannot throw (see §4). Today `InitToolSchemas` wipes first; a throw mid-`GetToolList` leaves the registry empty and builtins unvalidated.

Either way, **name used in the registry must be the prefixed public name** (`packId.FuncName`). `ValidateToolInput` / `FindSchema` compare the call’s `tool` string to `g_schemaToolNames[i]` with `==`. A schema stored as `FuncName` will not match a call to `packId.FuncName`.

Duplicate names: `FindSchema` returns the first hit; `InitToolSchemas` will happily insert the same name twice. Register must reject collisions with builtins and with other packs.

---

## 3. What `GetToolList` / `tools` must return for prefixed names

Forced by the map and glossary, not by current code (no pack merge exists):

- Public name is `packId.FuncName`. Not `packId.Editor_FuncName`. Builtins stay unprefixed (`GetMode`).
  - [`CONTEXT.md`](../../CONTEXT.md) “Prefixed tool name”
  - [#6](https://github.com/clankercode/tm-control-mcp/issues/6) “Forced tool names: `packId.FuncName`”
- Each list entry must keep the Anthropic shape already documented for in-process consumers:

```22:26:src/TmMcp_Export.as
    // Tool registry — names, descriptions, and input schemas in Anthropic
    // tool format ({name, description, input_schema}). Lets in-process
    // consumers (tm-agent) forward the live registry instead of
    // maintaining a duplicate list that drifts.
    import Json::Value@ GetToolList() from "TmMcp";
```

So a pack tool in the `tools` payload must look like:

```json
{
  "name": "my-plugin.Ping",
  "description": "...",
  "input_schema": { "type": "object", "properties": {}, "additionalProperties": false }
}
```

`name` is the key everything else uses:

- Socket `call` reads `request["tool"]` and passes it to `ValidateToolInput` then `CallTool` ([`Protocol.as` 61–80](../../src/Protocol.as)).
- Route-as-tool shortcut: `if (IsToolName(route)) { request["tool"] = route; … }` ([`Protocol.as` 52–54](../../src/Protocol.as)).
- Python `tools/call.py` indexes `t["name"]` → `input_schema` and rejects CLI names not in that map.
- README ground truth: `` `{"route":"tools"}` at runtime, or every `MakeTool("…")` ``.

Optional extra field `pack` on each entry is listed under “Not yet specified” in #6 (`ListToolPacks` vs only a `pack` field). Adding a field is backward-compatible for current consumers: `InitToolSchemas` only reads `name` + `input_schema`; `call.py` only requires `name`.

### Adjacent name gates (out of this ticket, but they will reject packs today)

These are **not** the schema registry, but they will make a pack tool look “unknown” even after the registry is fixed:

- `IsToolName` is a hardcoded `||` of builtin string literals ([`McpTools.as` 741–861](../../src/McpTools.as)). No prefix match.
- `DispatchAsync` rejects anything `!IsToolName` **before** `CallTool` ([`AsyncDispatchLocal.as` 15–16](../../src/AsyncDispatchLocal.as)). #6 says pack dispatch is sync and `DispatchAsync` wraps `CallTool` as today — so `IsToolName` (or this gate) must accept prefixed names, or async in-process calls to pack tools fail.
- `DispatchTool` is a hardcoded if-chain ending in `MakeError("unknown tool: " + name, "unknown_tool", …)` ([`McpTools.as` 886–1012](../../src/McpTools.as)). Packs need a fallback to the pack’s funcdef **before** that error.
- `CallTool` always returns `DispatchTool`’s object; it does not return null for unknown names. The `result is null` → `"unknown tool"` branch in `HandleCall` is therefore not the unknown-builtin path today.

---

## 4. Failure mode if a pack schema is invalid JSON

### `Json::Parse` throws

This codebase treats parse failure as an exception, not a null:

```7:11:src/Protocol.as
        try {
            @request = Json::Parse(payload);
        } catch {
            return MakeResponse("", "", null, "invalid JSON: " + getExceptionInfo());
        }
```

`MakeTool` does **not** catch:

```1142:1147:src/McpTools.as
    Json::Value MakeTool(const string &in name, const string &in description, const string &in inputSchemaJson) {
        Json::Value tool = Json::Object();
        tool["name"] = name;
        tool["description"] = description;
        tool["input_schema"] = Json::Parse(inputSchemaJson);
        return tool;
    }
```

`GetToolList` / `InitToolSchemas` do not catch either. Builtin schema strings are compile-time literals, so this is safe for today’s list. A pack-supplied string fed through `MakeTool` (or any unguarded `Json::Parse`) is not.

### If the throw happens during `InitToolSchemas`

Order of operations:

1. Both arrays `Resize(0)` — builtins gone.
2. `GetToolList()` rebuilds every builtin via `MakeTool` → `Json::Parse`, then (in a future pack-aware list) pack schemas.
3. Throw ⇒ function aborts ⇒ registry stays **empty**.
4. Every later `ValidateToolInput` hits `FindSchema < 0` and returns `""`.
5. Builtin calls still dispatch, but **unknown-key / required / type checks are gone**.

That is the “breaking builtin validation” failure mode #8 asked about.

If the throw happens on the `tools` route instead (`HandleRequest` → `GetToolList` with no try/catch around that call), the exception escapes `HandlePayload`’s request-parse try/catch (that catch only wraps the inbound payload). The `tools` listing fails as a whole; already-loaded schemas are unchanged.

### If parse is guarded and the value is junk

`InitToolSchemas` is defensive **after** a successful parse:

| `input_schema` value | Behavior |
|---|---|
| Missing key / null / not an object | `continue` — tool never enters `g_schema*`. |
| Object, no `properties` | `allowedKeys` empty. Any input key → `"unknown parameter"`. |
| Object, `properties` present, `type` is an array (union) | Key allowed; type check skipped. |
| Object, `type` missing / non-string | Same: type check skipped. |
| `required` missing / not an array | No required-key checks. |
| `additionalProperties` anything | Ignored. Unknown keys still rejected. |

A pack tool that is listed in `GetToolList` but skipped by the parser is **callable with no input validation** (`ValidateToolInput` returns `""`). That is the silent failure mode.

### Recommended register-time policy (for #11, not implemented)

1. Parse pack schema JSON in a `try/catch` **at `RegisterToolPack`**, never inside `GetToolList` / `InitToolSchemas`.
2. Reject the whole pack (or the one tool) with a returned error string; do not throw into TmMcp.
3. Store the already-parsed `Json::Value` object; `GetToolList` should append that object, not re-parse a string.
4. Do not call `InitToolSchemas()` from register/unregister unless `GetToolList` is throw-free. Prefer incremental insert/remove of the prefixed name.
5. Do not insert a schema unless it is a JSON object. Optionally require `type == "object"` so empty/non-object schemas cannot land as “validate nothing” or “reject everything”.

---

## 5. Direct answers

**Can pack tools join `ToolInputValidation` after `InitToolSchemas`?**

Yes, mechanically: `InsertLast` on the two parallel arrays with the prefixed name is enough; `FindSchema` / `ValidateToolInput` do not care when the row was added. There is no such helper today. Re-running `InitToolSchemas` only works if `GetToolList` already includes the pack tools **and** cannot throw.

**Can they be removed on unregister without breaking builtins?**

Yes, mechanically: remove the matching index from both arrays (or remove every name with prefix `packId.`). There is no such helper today. Re-running `InitToolSchemas` after unregister is only safe if `GetToolList` no longer lists that pack **and** the rebuild cannot throw. A wipe-then-rebuild that throws leaves builtins unvalidated.

**What must `GetToolList` return for prefixed names?**

`name` = `packId.FuncName`. Same `{name, description, input_schema}` object as builtins. Optional `pack` field is undecided and unused by the current parser/client.

**Failure mode for bad pack schema JSON?**

Unguarded `Json::Parse` throws. If that throw is on the `InitToolSchemas` → `GetToolList` → `MakeTool` path, the registry is already empty and builtin validation is gone. If parse is caught and the schema is not an object, that tool is omitted from the registry and its inputs are not validated.

---

## Sources

- [`src/ToolInputValidation.as`](../../src/ToolInputValidation.as) — `ToolSchema`, parallel arrays, `FindSchema`, `InitToolSchemas`, `ValidateToolInput`
- [`src/Main.as`](../../src/Main.as) — single `InitToolSchemas()` call at startup
- [`src/McpTools.as`](../../src/McpTools.as) — `IsToolName`, `CallTool`, `DispatchTool`, `GetToolList`, `MakeTool`
- [`src/Protocol.as`](../../src/Protocol.as) — `tools` route, `call` validation, `Json::Parse` try/catch
- [`src/AsyncDispatchLocal.as`](../../src/AsyncDispatchLocal.as) — `DispatchAsync` `IsToolName` gate
- [`src/TmMcp_Export.as`](../../src/TmMcp_Export.as) — exported `GetToolList` / Anthropic shape
- [`tools/call.py`](../../tools/call.py) — client schema cache keyed by `name`; `validate_input` mirror
- [`CONTEXT.md`](../../CONTEXT.md) — pack / packId / prefixed name / `ToolPackBuilder` glossary
- [#5](https://github.com/clankercode/tm-control-mcp/issues/5), [#6](https://github.com/clankercode/tm-control-mcp/issues/6), [#8](https://github.com/clankercode/tm-control-mcp/issues/8), [#11](https://github.com/clankercode/tm-control-mcp/issues/11)
