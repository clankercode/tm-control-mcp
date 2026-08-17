# Domain glossary

## Tool pack

A separate Openplanet plugin that registers named MCP tools into `tm-control-mcp` (`TmMcp`) at runtime. TmMcp never imports the pack plugin.

## Pack id

The namespace prefix for every tool the pack registers. Defaults to the Openplanet plugin id; override with `ToolPackBuilder("id")` or `SetPackId`. Appears in tool names as `packId.FuncName`. Custom ids must match `[A-Za-z][A-Za-z0-9_-]{0,63}`. Reserved: `core`, `tm-control-mcp`, `TmMcp`.

## Prefixed tool name

The public MCP tool name: `packId.FuncName`. Not `packId.Editor_FuncName`. Builtin TmMcp tools stay unprefixed (`GetMode`).

## ToolPackBuilder

Shared exported builder type a pack uses to declare its id, tools, schemas, and dispatch function before calling `RegisterToolPack`.
