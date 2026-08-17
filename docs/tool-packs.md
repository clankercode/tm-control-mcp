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

`packId` is the public MCP prefix (`packId.FuncName`). Default is the Openplanet plugin id. Override with `ToolPackBuilder("mypack")` or `SetPackId`. Tool names must not contain `.`.

`packId` must match `[A-Za-z][A-Za-z0-9_-]{0,63}`. Reserved: `core`, `tm-control-mcp`, `TmMcp`.

```angelscript
string g_PackId = "";

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
    auto b = TmMcp::ToolPackBuilder("mypack"); // or ToolPackBuilder() + SetPackId; default is this plugin's id
    b.AddTool("Ping", "Ping.", '{"type":"object","properties":{},"additionalProperties":false}');
    b.SetDispatch(MyDispatch);
    auto r = TmMcp::RegisterToolPack(b);
    if (r !is null && bool(r["success"])) g_PackId = string(r["output"]["pack"]);
}

void OnDestroyed() {
    if (g_PackId.Length > 0) TmMcp::UnregisterToolPack(g_PackId);
}
```

Dispatch receives the **unprefixed** name (`Ping`). Return `{success, output}` / `{success:false, error}` like builtin tools.

`RegisterToolPack` fails if that pack id is already registered — call `UnregisterToolPack` first (do this in `OnDisabled` / `OnDestroyed`). `UnregisterToolPack` accepts the custom prefix **or** the plugin id (drops every pack that plugin registered). Read `output.pack` from the register result.

Custom pack ids (constructor or `SetPackId`) must match the charset above. The default plugin id is not charset-checked (except it cannot contain `.`).

Adding the pack-id field / constructor is a shared-type change: reload TmMcp, then reload packs.

## Call back into TmMcp

Pack dispatch may call `TmMcp::CallTool`. Same tool must not re-enter itself (`reentrant_tool`). Each `CallTool` logs `TM Control MCP tool start/done`; pack dispatch also logs `TM Control MCP pack start/done`.

## Discovery

- `GetToolList` / `tools`: pack entries have `name` = `packId.FuncName` and `pack`.
- Builtin `ListToolPacks`: `{id, plugin, toolCount, enabled}`.

See `tools/fixtures/tm-mcp-pack-fixture/` for a working Ping / Echo / GetMode pack.

Hermes skill (agent trigger): `tm-mcp-tool-pack`.
