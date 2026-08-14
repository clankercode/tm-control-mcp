# Cross-plugin shared ToolPackBuilder and dispatch funcdef

Research for [issue #7](https://github.com/clankercode/tm-control-mcp/issues/7) (part of [#6](https://github.com/clankercode/tm-control-mcp/issues/6)). Not an implementation.

## Verdict

**Yes.** TmMcp can export a `shared` `ToolPackBuilder` plus a `shared funcdef` that a second plugin imports and uses to register tools, without TmMcp importing that plugin.

That is the normal Openplanet dependency direction: the pack lists TmMcp in `dependencies`; TmMcp does not list the pack. Function entry points live in `exports` (`import … from "TmMcp"`). Types that both modules must share (`shared class`, `shared funcdef`, `shared enum`) live in `shared_exports`.

**Not safe** to invoke a stored funcdef after the pack plugin is unloaded. Treat leftover handles as stale. Capture `Meta::ExecutingPlugin()` **at register time**. Before dispatch, drop the pack if `Meta::GetPluginFromID(id)` is null or `!Enabled`. Pack `OnDestroyed` must unregister; `OnDisabled` is a different hook (module still loaded). TmMcp should also sweep gone/disabled packs, matching the #6 destination note.

---

## Sources

| Source | What it owns |
| --- | --- |
| [openplanet.dev/docs/tutorials/plugin-dependencies](https://openplanet.dev/docs/tutorials/plugin-dependencies) | `exports` vs `shared_exports`, import syntax, shared-class rule |
| [openplanet.dev/docs/reference/info-toml](https://openplanet.dev/docs/reference/info-toml) | `exports`, `shared_exports`, `dependencies`, `module` |
| [openplanet.dev/docs/reference/plugin-callbacks](https://openplanet.dev/docs/reference/plugin-callbacks) | `OnDisabled` vs `OnDestroyed` |
| [openplanet.dev/docs/api/Meta](https://openplanet.dev/docs/api/Meta) and `ExecutingPlugin` / `Plugin` / `UnloadPlugin` / `GetPluginFromID` pages | plugin handle, enable, unload invalidation |
| [AngelScript: Shared script entities](https://www.angelcode.com/angelscript/sdk/docs/manual/doc_script_shared.html) | what can be `shared`; cannot touch non-shared |
| [AngelScript: Function handles](https://www.angelcode.com/angelscript/sdk/docs/manual/doc_datatypes_funcptr.html) | `funcdef` / delegates |
| This repo: `info.toml`, `src/TmMcp_Export.as`, `src/AsyncDispatch.as`, `src/AsyncDispatchLocal.as`, `src/PluginManager.as`, `src/Main.as`, `src/EditorOptional.as` | current TmMcp export split and ExecutingPlugin caching |
| First-party Openplanet plugins under `…/Trackmania/Openplanet/Plugins/` | VehicleState / Camera / Controls / NadeoServices patterns |
| Other Max plugins: Editor++ `Callbacks_Shared.as`, Skids Magician `Export_Shared.as` + `Callbacks.as`, Dips++ `Ex/Shared.as` | live `shared funcdef` + register/invoke |

The archived path `…/docs/reference/plugin-dependencies.md` is empty / not present. The live tutorial is `/docs/tutorials/plugin-dependencies` (linked from `info.toml` docs).

---

## 1. Openplanet export model

From [info.toml](https://openplanet.dev/docs/reference/info-toml) `[script]`:

- `exports`: files compiled into **dependent** plugins, **not** into this plugin.
- `shared_exports`: same as `exports`, except also compiled into **this** plugin.
- `dependencies`: required plugin IDs. Plugin will not load without them.
- `optional_dependencies`: load without the dep; no exported scripts and no `DEPENDENCY_x` define if missing.
- `module`: forced module name. “Only important when you intend to export functions to dependent plugins.” TmMcp already sets `module = "TmMcp"`.

From [Plugin Dependencies](https://openplanet.dev/docs/tutorials/plugin-dependencies):

- A depends on B ⇒ both must be installed for A to load. A inherits B’s exports.
- Exported functions (and optionally shared classes) run **in the context of the other plugin**.
- Two export lists:
  - `exports` — compiled into dependents only, **not** the dependency plugin.
  - `shared_exports` — compiled into **both**. “usually only useful if you want to provide classes using Angelscript’s shared entities.”
- Function exports use AngelScript `import` / `from`. The export file is **not** compiled with the host, so the real function is declared in a separate host file. Change the signature in both places.
- Exporting a class used as a return/parameter type:
  1. Put it in a regular `exports` file — **cannot** use that class in the host (export file is not compiled into the host).
  2. Make it `shared` and put it in `shared_exports` — both sides can use and pass handles.
- Quoted restriction (also on the AngelScript shared page):

  > Shared entities have a restriction in that they cannot access non-shared entities because the non-shared entities are exclusive to the script module in which they were compiled.

- If that restriction is painful, “it’s likely you can solve the problem without any shared entities, purely with exported functions.”

### AngelScript `shared` / `funcdef`

[Shared script entities](https://www.angelcode.com/angelscript/sdk/docs/manual/doc_script_shared.html):

- Benefits: same type across modules; lower memory.
- `shared` goes before the declaration (`shared class Foo`, `shared void GlobalFunc()`).
- Accessing a non-shared entity from a shared entity is a **compile error**.
- All modules must implement the shared entity the same way (same source file is the usual way).
- What can be shared: class, interface, function, enum, **funcdefs**.
- “Future versions may allow global variables to be shared too.” ⇒ **globals are not shared today.** A global in a `shared_exports` file is **per module**.

[Function handles](https://www.angelcode.com/angelscript/sdk/docs/manual/doc_datatypes_funcptr.html):

- A `funcdef` is a typed pointer to a global function with a matching signature.
- Compare with `is` / `is null`; call through the handle like a normal function.
- Class methods require a **delegate**: `CALLBACK @func = CALLBACK(obj.Method);` — the handle is bound to that instance.

Implication: a `shared funcdef` type can live in `shared_exports`. A handle of that type still points at a **specific function in a specific module** (or a delegate bound to a specific object). Sharing the *type* does not make the *target* survive module teardown.

---

## 2. What TmMcp already exports

`info.toml`:

```toml
module = "TmMcp"
exports = ["TmMcp_Export.as"]
shared_exports = ["AsyncDispatch.as"]
```

`src/TmMcp_Export.as` is the classic **import-only** surface (`exports`, not compiled into TmMcp):

```angelscript
import Json::Value@ CallTool(const string &in name, Json::Value &in input) from "TmMcp";
import bool IsToolName(const string &in name) from "TmMcp";
import Json::Value@ GetToolList() from "TmMcp";
import Json::Value@ DispatchAsync(...) from "TmMcp";
import Json::Value@ GetResult(...) from "TmMcp";
```

Comment in that file: individual tools use `Json::Value &in` and import requires matching signatures, so the public surface is name-based dispatch rather than one import per tool.

`src/AsyncDispatch.as` (`shared_exports`) holds `shared class AsyncToolResult` plus **non-shared** module globals `g_PendingRequests` / `g_AsyncInputs`. Those dictionaries are compiled into TmMcp **and** into each dependent, but they are **not** the same storage (AngelScript: globals cannot be shared).

`src/AsyncDispatchLocal.as` is explicitly **not** in `shared_exports` because it references `CallTool` / `IsToolName` (non-shared host symbols). That split is the template for ToolPackBuilder: shared types in `shared_exports`; host-only registry / `CallTool` wiring stays out.

---

## 3. First-party Openplanet plugins

| Plugin | `exports` | `shared_exports` | What’s in shared |
| --- | --- | --- | --- |
| **VehicleState** | `Export.as` — `import … from "VehicleState"` | `StateWrappers.as` | `shared enum` + `shared class CSceneVehicleVisState` (and inner abstract) |
| **Camera** | `Export.as` — imports only | *(none)* | No shared types. Functions only. |
| **Controls** | `Export.as` — imports | `ExportShared.as` | `const vec4` color tokens (not even `shared class`) |
| **NadeoServices** | `Export.as` — imports | *(none)* | Auth/token work stays inside NadeoServices; dependents only call imported functions. Tutorial’s “one token, many dependents” example. |

VehicleState is the official “shared class in `shared_exports` + `import` functions in `exports`” pattern. Camera shows you do **not** need `shared_exports` if you only export functions. Neither first-party plugin stores a funcdef from a dependent and invokes it later.

---

## 4. Cross-plugin `shared funcdef` in the wild

This is the closest analog to “pack registers a callback; host invokes it later.”

### Editor++ — shared class holding funcdef fields

`tm-editor-plus-plus/info.toml`: `module = "Editor"`, `shared_exports` includes `Exports/Callbacks_Shared.as`, `exports` includes `Exports/Callbacks.as`.

`Callbacks_Shared.as` (compiled into Editor **and** dependents):

- `shared funcdef bool ProcessItem(...)` (and siblings).
- `shared class IEppExtension` with fields of those funcdef types (`ProcessItem@ onPlaceItem`, `CoroutineFunc@ onEditorLoad`, …).
- Comment: inherit, set the handles you want, leave others null, then `RegisterExtension`. “Handles to callback functions must be set at this time for them to be registered.”
- `kill()` comment: **“should be called from the plugin’s OnDestroyed method to avoid keeping stale references.”**

`Callbacks.as` (`exports` only):

```angelscript
import void RegisterExtension(IEppExtension@ extension) from "Editor";
```

`Callbacks_Impl.as` (host-only): stores extension handles; on each run, if `ext is null || ext.isDead || <funcdef> is null`, remove immediately and **do not call**.

This is the shape ToolPackBuilder should copy: shared types + import `Register*` / (implied) unregister; host owns the list; dead/null handles are skipped.

### Skids Magician — funcdef + `ExecutingPlugin` at register

`Export_Shared.as`:

```angelscript
shared funcdef void OnVehicleStateUpdated(uint VehicleEntityId, uint64 VehicleStatePtr);
```

`Export_Code.as` (`exports`):

```angelscript
import void RegisterOnVehicleStateUpdateCallback(OnVehicleStateUpdated@ func) from "SkidsMagician";
import void DeregisterVehicleStateUpdateCallbacks() from "SkidsMagician";
```

`Callbacks.as` (host-only):

- `RegisterOnVehicleStateUpdateCallback` records `Meta::ExecutingPlugin().ID` **next to** the funcdef.
- Invoke wraps `f(...)` in `try/catch` and names the stored plugin id in the warning.
- `DeregisterVehicleStateUpdateCallbacks` uses `Meta::ExecutingPlugin()` again (the **calling** plugin, via the imported function).
- Does **not** re-query `ExecutingPlugin` at invoke time to decide whose callback it is.

### Dips++ — shared funcdef stored by the host

`shared_exports = ["Ex/Shared.as"]` declares `shared funcdef void DPP_TaskCallback(...)`. Host `Tasks.as` stores `DPP_TaskCallback@[]` and later calls `cb(...)`. Same split: type is shared; the array lives in host-only code.

### Other shared-type hosts (no funcdef)

- MLFeed: `shared_exports = ["MLFeed_ExportShared.as"]` — many `shared class` hooks/proxies; `export_dependencies = ["MLHook"]` because those shared types mention MLHook types.
- Ghosts++: `shared interface` + `shared class`.
- Map Info: `shared enum` + `shared class Data`.

If a shared ToolPack type ever mentioned a type from another plugin, TmMcp would need `export_dependencies` the same way MLFeed re-exports MLHook.

---

## 5. `Meta::ExecutingPlugin()` — register vs later dispatch

Docs: [`Meta::ExecutingPlugin()`](https://openplanet.dev/docs/api/Meta/ExecutingPlugin) — “Gets the currently executing plugin.” Returns `Meta::Plugin@`. No further contract.

This repo already treats the import-call case as **caller, not callee**. `src/PluginManager.as`:

> Cached handle to THIS plugin. `Meta::ExecutingPlugin()` returns the caller’s plugin when an exported function is invoked in-process from another plugin, so “self” must be resolved once at startup, not per-call.

`Main()` calls `CacheSelfPlugin()` before anything else so in-process `CallTool` from tm-agent does not mis-identify TmMcp.

Therefore, inside `RegisterToolPack` (an imported function in TmMcp, called by the pack):

- `Meta::ExecutingPlugin()` is the **pack plugin**.
- That is the moment to stamp owner id / keep a `Meta::Plugin@` for later `Enabled` checks.
- Do not ask the pack to pass its own id as the source of truth; Skids Magician already uses ExecutingPlugin this way.

At **later dispatch**, when TmMcp calls the stored funcdef:

- No Openplanet page states which plugin `ExecutingPlugin()` returns (caller TmMcp vs pack module whose function is running).
- Skids Magician does not use ExecutingPlugin at invoke time for ownership.
- Pack dispatch code should not assume `ExecutingPlugin()` is the pack.

`GetPluginFromID` ([docs](https://openplanet.dev/docs/api/Meta/GetPluginFromID)): “Gets a plugin from its ID.” This repo already uses `p !is null && p.Enabled` as the liveness test (`src/EditorOptional.as` `IsEditorPlusPlusAvailable()`).

`Meta::Plugin` ([docs](https://openplanet.dev/docs/api/Meta/Plugin)): `ID`, `Enabled` get/set, `SourcePath`, `Type`, etc. Disabled plugins remain loaded objects with `Enabled == false`.

---

## 6. Safety after pack unload / reload

### What the docs say

- `OnDestroyed`: “Called when the plugin is unloaded and completely removed from memory.” ([plugin-callbacks](https://openplanet.dev/docs/reference/plugin-callbacks))
- `Meta::UnloadPlugin`: “Queues a plugin to be unloaded from memory completely when it is safe to do so. Note that this will **invalidate the plugin object passed in on the next frame**! Do not use the Plugin handle after calling this!”
- `Meta::ReloadPlugin`: same invalidation warning.
- `Meta::UnloadedPlugins()`: identifiers of unloaded plugins; “may be slow.”

### What that means for a stored funcdef

A `funcdef` handle / delegate points at code (and possibly an object) in the pack’s module. After `OnDestroyed`, that module is gone. Official docs do not describe “nulling” such handles. Editor++ explicitly calls leftover extension refs **stale** and requires `OnDestroyed` → `kill()`.

**Do not invoke a pack funcdef after unload.** There is no cited safe “probe the handle” API beyond `is null`, and a leftover non-null handle is exactly the stale case E++ warns about.

Reload: the new plugin instance is a new module. Old funcdefs still point at the old module. The new instance must `RegisterToolPack` again. If the old pack is still in TmMcp’s table, TmMcp is holding stale pointers.

### Host-side sweep (required, not optional)

Issue #6 already decided: “Packs unregister in `OnDestroyed`; TmMcp also drops a pack if the plugin is gone/disabled.”

Facts that support that:

- Unload can happen without the pack’s `OnDestroyed` successfully calling into TmMcp (exception, timeout, TmMcp already tearing down).
- After unload, `GetPluginFromID(packId)` is the cheap “gone?” test this repo already uses.
- After disable, the plugin object still exists (`Enabled == false`); funcdefs are still technically in a live module, but the pack is off — do not dispatch.
- Store **plugin id string** (and optionally a handle that is re-resolved each dispatch). Do not keep a `Meta::Plugin@` across an unload/reload without re-fetching; UnloadPlugin invalidates it next frame.

Suggested check before every pack invoke (same predicate as `IsEditorPlusPlusAvailable`):

```angelscript
auto p = Meta::GetPluginFromID(ownerId);
if (p is null || !p.Enabled) { /* drop pack; do not call funcdef */ }
```

---

## 7. `OnDestroyed` vs `OnDisabled`

[plugin-callbacks](https://openplanet.dev/docs/reference/plugin-callbacks):

| Hook | When |
| --- | --- |
| `OnDisabled()` | Plugin disabled from settings, menu, or Meta API. |
| `OnEnabled()` | Plugin re-enabled the same ways. |
| `OnDestroyed()` | Plugin **unloaded and completely removed from memory**. |

Disable ≠ destroy. Disabled plugin: still loaded, `GetPluginFromID` works, `Enabled` is false, module still exists. Destroyed plugin: gone, handle invalid next frame, funcdefs stale.

TmMcp itself (`src/Main.as`) calls `TmMcp::Shutdown()` from **both** `OnDestroyed` and `OnDisabled`. Same pairing in MLFeed, Skids Magician, chat-logger, customize-cp-counter, etc.

Editor++’s exported comment names **`OnDestroyed`** specifically for `kill()` (stale refs). That matches “module is leaving memory.”

### Recommendation for packs (and for TmMcp’s authoring doc later)

- **Must:** `OnDestroyed` → `UnregisterToolPack`. This is the unload/reload path. Matches #6 and E++.
- **Should:** `OnDisabled` → same unregister, so toggling the pack off removes tools even if TmMcp’s sweep is late. Matches TmMcp’s own Main.as and most Max plugins.
- **Must (host):** TmMcp sweep on gone **or** `!Enabled` before dispatch. Covers a pack that only unregisters in `OnDestroyed`, or fails to unregister.
- Re-enable: pack `OnEnabled` / `Main` must register again. TmMcp should not keep a disabled pack’s funcdef “warm.”

---

## 8. Implications for ToolPackBuilder (facts only)

These follow from the sources; they are not an API sketch (that is #11).

1. **Dependency direction works.** Pack `dependencies = ["…TmMcp id…"]`. TmMcp does not import the pack. Same as every host above.
2. **Split files like VehicleState / E++ / current TmMcp:**
   - `shared_exports`: `shared class ToolPackBuilder`, `shared funcdef` for pack dispatch (and any helper types the builder/dispatch must mention).
   - `exports`: `import void RegisterToolPack(...) from "TmMcp"` and `UnregisterToolPack`.
   - Host-only file: the actual register/unregister, the pack table, invoke + sweep. Must not sit in `shared_exports` if it touches `CallTool` / non-shared registry (see `AsyncDispatchLocal.as`).
3. **Builder methods cannot call TmMcp internals.** Shared entities cannot access non-shared entities. `RegisterToolPack` is an imported host function, not a method that reaches into TmMcp’s private registry.
4. **Do not put the pack table in `shared_exports` globals.** Those globals are per-module copies. Dependents would not see TmMcp’s table.
5. **Stamp owner at register** with `Meta::ExecutingPlugin().ID` (and cache TmMcp’s own plugin in `Main`, already done).
6. **Invoke is host-driven.** TmMcp calls the stored funcdef later. That is proven (E++, Skids, Dips++). It is not an `import` back from TmMcp into the pack.
7. **Stale after unload.** Unregister in `OnDestroyed`; host sweep `null || !Enabled`; never call a leftover handle.
8. **`export_dependencies`:** only if shared types mention another plugin’s types (MLFeed → MLHook). Not needed for Json::Value / built-in types.

---

## 9. Open / not proven from sources

- Exact `ExecutingPlugin()` value **inside** a pack funcdef while TmMcp is calling it. Do not rely on it.
- Whether Openplanet nulls funcdef handles on module discard, or whether a leftover handle crashes vs throws. E++ treats them as stale; design as if invoke is undefined.
- Whether a still-held funcdef/delegate can keep a discarded module alive (AngelScript engine can; Openplanet’s “removed from memory” wording suggests they do not want that). Unregister anyway.
- `packId` charset vs plugin id — out of this ticket (#9).
- Builder method names / schema objects — out of this ticket (#8, #11).
