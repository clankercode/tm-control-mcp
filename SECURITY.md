# Security

## Summary (read this first)

`tm-control-mcp` is a **local control plane** for Trackmania via Openplanet. It
listens on a **TCP JSON socket** (default **`127.0.0.1:30006`**) and executes
powerful editor/menu operations on behalf of any client that can connect.

| Fact | Detail |
|------|--------|
| Bind | **Localhost only by default** — do **not** bind to `0.0.0.0` or a LAN IP |
| Auth | **None** — any process on the machine can call tools while the plugin is loaded |
| Impact | Mutate/clear maps, drive menus, inject ManiaScript, enable/disable plugins, read/write plugin settings, DEV memory tools |
| Trust model | Same as “a debugger attached to your game client” |

If that is unacceptable for your environment, **do not load the plugin**.

---

## Threat model

### In scope

- Accidental or malicious **local** clients (other users/processes on the same host)
- Agents that call destructive tools without readiness checks (`ClearMapContent`, menu play launches, `ControlPlugin unload`, …)
- ManiaScript injection (`RunManialinkScript`) causing game instability or recovery restarts
- DEV tools exposing process memory layout (`DevSafeRead`, pointer dumps)
- Settings changes that move the socket (host/port) or enable request tracing (logs may contain payloads)

### Out of scope (not defended)

- Remote attackers **unless you rebind the socket off localhost** (then you have no auth — catastrophic)
- Compromised Openplanet / game process integrity
- Nadeo account / online service security
- Multi-tenant shared machines without OS user isolation

---

## Hardening checklist

1. **Keep Socket Host = `127.0.0.1`**  
   Openplanet → Settings → **TM Control MCP** → Server → Socket Host.  
   Also: `GetPluginSetting` / `ListPluginSettings` category `Server`.

2. **Do not port-forward / tunnel the control port** into untrusted networks.

3. **Prefer provenance cleanup** (`SetAgentTag` + `RemoveByTag`) over `ClearMapContent` in agent loops.

4. **Treat DEV tools as trusted-developer only**  
   `DevSafeRead`, `DevGetPointers`, `DevComputeItemsPointers`, `RunRandomFuzz`, etc.  
   are registered **only when built with `defines = ["DEV"]`** (folder dev staging).  
   Release `.op` builds omit them from the tool list. Still: do not expose the socket on shared hosts.

5. **Plugin manager guards**  
   `ControlPlugin` refuses **disable/unload of itself** so a client cannot brick the channel accidentally.  
   `reload` of self still drops the socket until reload finishes.

6. **Settings writes**  
   `SetPluginSetting` + `SavePluginSettings` persist Openplanet settings.  
   Host/port changes need a **plugin reload** to take effect; a hostile local client could still change them.

7. **Logs**  
   `Trace Requests` logs full request/response payloads to `Openplanet.log` — disable unless debugging.

8. **Script timeout**  
   `info.toml` `timeout = 15000` limits runaway script time; it is not a security boundary.

---

## Reporting issues

This is a small public-domain project. Prefer:

1. GitHub issues on [clankercode/tm-control-mcp](https://github.com/clankercode/tm-control-mcp) for non-sensitive bugs
2. For issues that would help an attacker on a mis-bound socket, email the maintainer listed in `info.toml` (`XertroV`) or open a **private** advisory if/when GitHub security advisories are enabled on the repo

Please include Openplanet version, plugin version, and whether the socket host was left at localhost.

---

## License / warranty

Dual Unlicense / CC0 — **no warranty**. See [LICENSE](./LICENSE).
