# Writing a TmMcp tool pack

A **tool pack** is a separate Openplanet plugin that registers MCP tools into `tm-control-mcp` at runtime. TmMcp never imports the pack.

## Depend on TmMcp

```toml
[script]
dependencies = ["tm-control-mcp"]
module = "MyPack"
```

`ToolPackBuilder` / `ToolPackDispatch` come from TmMcp `shared_exports`. `RegisterToolPack` / `UnregisterToolPack` / `CallTool` come from `exports`.

## Register

`packId` is always the Openplanet plugin id (custom ids later). Tool names must not contain `.`. Public MCP names are `packId.FuncName`.

```angelscript
Json::Value@ MyDispatch(const string &in name, Json::Value &in input) {
    if (name == "Ping") {
        auto o = Json::Object();
        o["pong"] = true;
        auto r = Json::Object();
        r["success"] = true;
        r["output"] = o;
        return r;
    }
    auto err = Json::Object();
    err["success"] = false;
    err["error"] = "unknown tool: " + name;
    return err;
}

void Main() {
    auto b = TmMcp::ToolPackBuilder();
    b.AddTool("Ping", "Ping.", '{"type":"object","properties":{},"additionalProperties":false}');
    b.SetDispatch(MyDispatch);
    auto r = TmMcp::RegisterToolPack(b);
}

void OnDestroyed() {
    auto p = Meta::ExecutingPlugin();
    if (p !is null) TmMcp::UnregisterToolPack(p.ID);
}
```

Dispatch receives the **unprefixed** name (`Ping`). Return `{success, output}` / `{success:false, error}` like builtin tools.

`RegisterToolPack` fails if that pack id is already registered — call `UnregisterToolPack` first (do this in `OnDisabled` / `OnDestroyed`).

Reserved pack ids: `core`, `tm-control-mcp`, `TmMcp`.

## Call back into TmMcp

Pack dispatch may call `TmMcp::CallTool`. Same tool must not re-enter itself (`reentrant_tool`). Each `CallTool` logs `TM Control MCP tool start/done`; pack dispatch also logs `TM Control MCP pack start/done`.

## Discovery

- `GetToolList` / `tools`: pack entries have `name` = `packId.FuncName` and `pack`.
- Builtin `ListToolPacks`: `{id, plugin, toolCount, enabled}`.

See `tools/fixtures/tm-mcp-pack-fixture/` for a working Ping / Echo / GetMode pack.

Hermes skill (agent trigger): `tm-mcp-tool-pack`.
