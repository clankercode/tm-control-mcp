# Tier A Agent Ergonomics — Implementation Plan

> **For Hermes:** Use subagent-driven-development (or sequential PIRFL) task-by-task. Prefer TDD where Python-side; live Openplanet smoke for AS tools. Do **not** invent version bumps.

**Goal:** Ship the Tier A shortlist so agents can preflight, wait, clean up safely, control editor mode/inventory, get ML results, and persist named macroblocks — without thrashing on polls or nuking user content.

**Architecture:** Thin MCP tools on top of existing E++ exports (`SetEditMode` / `SetPlacementMode` / `SetSelectedBlockInfo` / place-delete). New plugin-local state for provenance tags, snapshots, and named-MB disk I/O. Extend `MakeError` + `call.py` for structured errors and wait helpers. Prefer **one multi-action tool** per domain (`ControlEditMode`, `ControlInventory`) matching `ControlCursor` / `ControlCamera` style.

**Tech stack:** AngelScript Openplanet plugin (`tm-control-mcp`), E++ `Editor` exports, MLHook inject, `tools/call.py`, optional tiny Python tests for client helpers.

**Baseline commit:** `f87f3e1` (RunManialinkScript + docs). Live tools ≈ 84. Build: `TM_PLUGIN_SKIP_LSP=1 ./build.sh dev` when LSP false-positives flood; game `Loaded plugin` is ground truth.

---

## Scope (ordered phases)

| Phase | Deliverables | Effort | Depends on |
|-------|--------------|--------|------------|
| **P0** | `GetReadiness`, `WaitUntil`, call.py wait helpers | S | none |
| **P1** | Structured errors (soft, additive) | S–M | P0 optional |
| **P2** | Provenance tags + `RemoveByTag` / scoped cleanup | M | none (pairs with P0 smokes) |
| **P3** | `ControlEditMode` + item/MB select models | S–M | E++ exports already exist for mode/block |
| **P4** | `ControlInventory` (select/open article) | M | may need **new E++ export** |
| **P5** | ML result channel for `RunManialinkScript` | M | MLHook already |
| **P6** | Durable named-MB save/load + `AssertPlacement` | M | P0 nice for verify |

**Out of scope this plan:** mood mutation, absolute cursor (tiny follow-up), full job queue, McpTools.as split, SSIM screenshots.

**YAGNI rules:**
- No full multi-agent lock server — tags + readiness first.
- No generic “transaction manager” — snapshot fingerprint is enough for Assert/cleanup.
- Inventory select: only if E++/engine path is clean; otherwise document “path-place is preferred” and ship mode/select-model only.

---

## Ground truth (code)

| Need | Exists today | Path |
|------|--------------|------|
| Mode / dialog / inventory counts | Separate tools | `GetMode`, `GetDialog`, `GetInventorySummary`, `GetMapInfo` |
| Editor ready flag | Used in BackToMainMenu | `editor.PluginMapType.IsEditorReadyForRequest` |
| Edit/place mode set | E++ exports | `Editor::SetEditMode`, `Editor::SetPlacementMode` (`Exports_General.as`) |
| Block select | MCP + E++ | `SelectBlockModel` → `SetSelectedBlockInfo` |
| Inventory select node | E++ **internal only** | `Editor::SetSelectedInventoryNode` in `Editor.as` — **not in exports** |
| Named MB memory | MCP arrays | `g_NamedMacroblockNames/Specs/Skins` in `McpTools.as` |
| Place/delete | MCP → E++ | `Place*`, `RemoveRecentItems` → `DeleteItems` |
| ML inject | MCP | `RunManialinkScript` / `ManialinkRunner.as` |
| Errors | string only | `MakeError(err)` → `{success:false, error}` |
| Client | process check, `--strict` | `tools/call.py` |

---

## Phase P0 — Readiness + Wait (ship first)

### Goal
One composite preflight + one poll-until tool + client helpers so agents stop multi-calling `GetMode`/`GetDialog`/`GetMapInfo`.

### Tool contracts

#### `GetReadiness`
```json
// input: {} or { "want": "editor" | "menu" | "any" }
// output:
{
  "ready": true,
  "mode": "Editor",
  "want": "editor",
  "checks": {
    "trackmaniaProcess": true,   // filled by call.py only; plugin omits or true
    "socketAlive": true,
    "modeOk": true,
    "dialogClear": true,
    "editorReadyForRequest": true,
    "inventoryReady": true,
    "hasChallenge": true
  },
  "dialog": { "active": false },
  "map": { "nbBlocks": 4112, "nbItems": 3, "name": "Unnamed" },
  "inventory": { "isScanningItems": false, "nbItems": 5936 },
  "blockingReasons": []
}
```

Rules:
- `ready=false` if any check fails for `want`.
- `want=editor`: mode Editor + `IsEditorReadyForRequest` + no blocking dialog + inv not scanning (warn-only if scanning).
- `want=menu`: mode Menu + menu module available (reuse SetMenuPage gate patterns).
- Never mutate.

#### `WaitUntil`
```json
// input:
{
  "condition": "mode|dialogClear|editorReady|pageVisible|mapItems|mapBlocks|readiness",
  "equals": "Editor",          // mode
  "page": "Page_MapEditorSettings",
  "op": "eq|gte|lte",          // for counts
  "count": 0,
  "want": "editor",            // for readiness
  "timeoutMs": 15000,
  "pollMs": 100
}
// output: { "ok": true, "elapsedMs": 420, "last": { ...snapshot... }, "timedOut": false }
```

Implementation: yield loop in tool coroutine (plugin already yields in CreateMapViaMenu / BackToMainMenu). Cap `timeoutMs` ≤ 60000, `pollMs` ≥ 50.

#### `tools/call.py`
```
--wait-mode Editor|Menu|Race
--until-ready editor|menu
--wait-timeout 30
```
Client loop: call `WaitUntil` / `GetReadiness` until ok or budget. Keep compact JSON default.

### Files
- Create: `src/Readiness.as` (`GetReadiness`, `WaitUntil`, shared snapshot helper)
- Modify: `src/McpTools.as` — register tools
- Modify: `tools/call.py` — wait flags
- Modify: `README.md`, `AGENTS.md`, guide topic `readiness`
- Test: `tests/test_call_wait.py` (mock socket or unit-test arg parsing + loop logic with fake responses)

### Tasks

#### Task P0.1 — Snapshot helper + GetReadiness (AS)
1. Add `ReadinessSnapshot()` building mode/dialog/editor/inv/map fields (reuse `GetMode`/`GetDialog`/`MapSummary`/`GetInventorySummary` internals — extract shared bits, don’t call tools via JSON).
2. Implement `GetReadiness`.
3. Register in `IsToolName` / `CallTool` / `GetToolList`.
4. Build+reload; smoke:
   ```bash
   python3 tools/call.py --pretty GetReadiness '{"want":"editor"}'
   ```
   Expect `ready=true` when already in Editor with no dialog.

#### Task P0.2 — WaitUntil (AS)
1. Implement condition switch + yield loop.
2. Smoke: `WaitUntil mode=Editor` returns immediately; `mode=Menu` with short timeout → `timedOut=true` while in Editor.

#### Task P0.3 — call.py wait helpers
1. Parse `--wait-mode` / `--until-ready` / `--wait-timeout`.
2. Before main tool call (or as standalone if only wait flags), run wait loop.
3. Unit test without game: mock `send_request`.

#### Task P0.4 — Docs + commit
```
feat(mcp): GetReadiness + WaitUntil + call.py wait helpers
```

---

## Phase P1 — Structured errors (additive)

### Goal
Agents can branch on `code` without scraping English strings. **Backward compatible:** keep `error` string.

### Shape
```json
{
  "success": false,
  "error": "editor not available",
  "code": "NOT_IN_EDITOR",
  "retryable": true,
  "requiredMode": "Editor",
  "hint": "Use CreateMapViaMenu or WaitUntil mode=Editor"
}
```

### Codes (v1 enum, string)
`NOT_IN_EDITOR`, `NOT_IN_MENU`, `DIALOG_BLOCKING`, `EDITOR_BUSY`, `INVALID_INPUT`, `NOT_FOUND`, `TIMEOUT`, `INJECT_FAILED`, `DELETE_FAILED`, `PLACE_FAILED`, `UNKNOWN`

### Files
- Modify: `MakeError` → `MakeError(msg, code="", retryable=false, requiredMode="", hint="")` in `McpTools.as` (or `Protocol.as` helpers)
- Migrate high-traffic call sites first: GetCursor, place/delete, menu tools, RunManialinkScript, WaitUntil timeout
- Optional: call.py prints `code`/`hint` on stderr when present
- Docs: README error section

### Tasks
1. Extend `MakeError` with optional kwargs (AS: overloads or default params).
2. Convert ~15 highest-value sites.
3. Smoke one forced error; confirm old clients still read `error`.
4. Commit: `feat(mcp): structured error fields on tool failures`

**Do not** rewrite every MakeError in one PR.

---

## Phase P2 — Provenance tags + scoped cleanup

### Goal
Every agent place can tag objects; cleanup removes only tagged leftovers (fuzz/smoke) without `ClearMapContent`.

### Design
Plugin-side maps (survive until reload; optional disk later):

```
// keyed by stable-ish identity: for items use (index at place time is unstable)
// Prefer: world pos hash + model idName + generation counter
struct TaggedObject {
  string tag;       // "run:smoke-42" or sessionId
  string kind;      // "block" | "item"
  string idName;
  vec3 pos;         // world
  uint placedAtMs;
  int lastKnownIndex; // hint only
}
array<TaggedObject@> g_Tags;
string g_DefaultTag; // set via SetAgentTag
```

**Tagging hooks:** after successful:
- `PlaceBlockViaEditorPlusPlus` / `PlaceItemViaEditorPlusPlus`
- `PlaceNamedMacroblock`
- optionally `RunRandomFuzz` auto-tag `fuzz:<timestamp>`

**Tools:**
| Tool | Role |
|------|------|
| `SetAgentTag` | `{ "tag": "run:abc" }` default for subsequent places; `{ "tag": "" }` clear |
| `ListTagged` | filter by tag/prefix; return matches with current index resolution |
| `RemoveByTag` | resolve live indices via pos+idName match (±ε), call DeleteItems/DeleteBlocks; report deleted/missed |
| `ClearTagIndex` | drop sidecar only (not map) |

**Match algorithm (items):** scan `AnchoredObjects` for `idName` + position within ε (default 0.05 m).  
**Blocks:** freeblocks by pos; grid blocks by coord+model.

### Files
- Create: `src/Provenance.as`
- Modify: placement tools to call `RecordPlacement(...)` when `g_DefaultTag` non-empty or input `tag` set
- Modify: `RemoveRecent*` docs — prefer RemoveByTag for agent cleanup
- Guide: `agent-cleanup`
- Smoke: place 3 tagged pillars → RemoveByTag → count back; untagged user items untouched

### Tasks
1. Data structures + SetAgentTag/ListTagged.
2. Hook PlaceItem + PlaceBlock E++ paths.
3. RemoveByTag using existing delete paths (`forceBufferFallback=false`).
4. Live multi-cycle smoke; commit `feat(mcp): agent provenance tags and RemoveByTag`.

**Risk:** index churn after deletes — always re-resolve by pos/idName, never trust stale index alone.

---

## Phase P3 — ControlEditMode + model select

### Goal
Agents can enter Place/Erase/FreeLook and Block/FreeBlock/Item/Macroblock modes; select item/MB models like blocks.

### Tool: `ControlEditMode`
```json
{
  "action": "status|setEdit|setPlace|set",
  "editMode": "Place|Erase|FreeLook|Pick|...",  // string names mapped to enum
  "placeMode": "Block|FreeBlock|GhostBlock|Item|FreeItem|Macroblock|FreeMacroblock|CustomSelection|...",
  "blockName": "...",   // optional after set
  "itemPath": "...",
  "macroblock": "..."
}
```

- `status` → reuse/extend `GetEditorSelectionState` fields + string names for enums.
- `set` / `setEdit` / `setPlace` → `Editor::SetEditMode` / `SetPlacementMode`.
- After set, optional select model via existing `SelectBlockModel` path + new item/MB select.

### Enum mapping
Implement `EditModeFromString` / `PlaceModeFromString` with explicit allowlist; unknown → `INVALID_INPUT`.

### SelectItemModel / SelectMacroblockModel
- Item: resolve `GetInventoryItemModelByPath` + editor item selection APIs (grep E++ for `SetSelectedItem` / item cursor model setters — if only inventory node works, defer to P4).
- MB: `Editor::SetSelectedMacroBlockInfo` if exported; else add thin export in E++.

### E++ work (if needed)
Check exports for:
- `SetSelectedMacroBlockInfo`
- Item model selection helper

If missing: small E++ PR first, rebuild E++ then MCP.

### Files
- Create: `src/EditModeControl.as`
- Modify: `McpTools.as` router; import E++ setters
- Smoke: set FreeBlock Place → GetEditorSelectionState confirms; set Item mode + select ObstaclePillar2m

### Commit
`feat(mcp): ControlEditMode and item/macroblock model select`

---

## Phase P4 — ControlInventory

### Goal
Select/open inventory articles/folders the way a human picker does (when path-place is not enough).

### Prerequisite spike (Task P4.0 — half day max)
1. Confirm `Editor::SetSelectedInventoryNode` / folder APIs behavior on live BlueBay.
2. Export from E++ if good:
   ```angelscript
   // Exports_General.as + info.toml exports list
   void SetSelectedInventoryNode(CGameCtnEditorFree@, CGameCtnArticleNodeArticle@, bool isItem);
   void SetSelectedInventoryFolder(...);
   ```
3. If spike fails: ship P3 only; document “use Place* path APIs”; stop.

### Tool: `ControlInventory`
```json
{
  "action": "status|select|openFolder",
  "type": "block|item|macroblock",
  "path": "ObstaclePillar2m",
  "query": "optional find first"
}
```
Reuse `BrowseInventoryTree` / FindInventory resolution for paths.

### Files
- E++: export + rebuild
- MCP: `src/InventoryControl.as`
- Smoke: select item article → GetEditorSelectionState / cursor shows model

### Commit
`feat(mcp): ControlInventory via E++ inventory selection exports`

---

## Phase P5 — RunManialinkScript result channel

### Goal
Ad-hoc ML can return data to the agent without permanent hooks.

### Design (minimal)
1. MCP registers a short-lived `MLHook::HookMLEventsByType` for type `McpAdHoc_Result` (or pageUid-scoped).
2. Injected script convention:
   ```javascript
   // ManiaScript
   main() {
     // ... work ...
     SendCustomEvent("MLHook_Event_McpAdHoc_Result", ["ok", "payload-string"]);
     // or Queue through MLHook documented pattern used by autosave-ghosts
   }
   ```
3. Tool inputs add:
   - `collectMs` (default 0 = fire-and-forget)
   - `resultEvent` (default `McpAdHoc_Result`)
4. Output adds `results: string[][]` / `events` collected during wait.
5. Unregister hook after collect window; still cleanup page per `persist`.

**Alternative if SendCustomEvent from injected page is awkward:** script writes to a known `declare Text` on a frame label that AS reads via layer tree — uglier; prefer event hook.

### Spike P5.0
Prove one inject in editor that emits event MCP receives (copy pattern from `tm-autosave-ghosts` / MLFeed).

### Files
- Modify: `ManialinkRunner.as`
- Guide: `manialink-runner` update with result recipe
- Smoke: script sends `"ping"` → results contain ping

### Commit
`feat(mcp): collect MLHook events from RunManialinkScript`

**Safety:** cap collected events (e.g. 64) and payload chars; never hang past `collectMs`.

---

## Phase P6 — Durable named-MB + AssertPlacement

### Goal
Named macroblocks survive reload; agents get one-shot placement verification.

### Durable named-MB
**Format:** JSON under Openplanet data folder, e.g.  
`IO::FromDataFolder("tm-control-mcp/named-mb/<name>.json")`

Contents: blocks/items arrays mirroring AddBlock/AddItem specs (blockName/itemPath, x,y,z, rot, variant, skins).

**Tools:**
- `SaveNamedMacroblock { name, fileName? }`
- `LoadNamedMacroblock { name, fileName?, replace:true }`
- Optional: list files on disk

**Not v1:** round-trip through real `.Macroblock.Gbx` (harder; E++ donor paths) — JSON is enough for agent libraries.

### `AssertPlacement`
```json
{
  "expectItemsDelta": 1,
  "expectBlocksDelta": 0,
  "near": { "x": 900, "y": 40, "z": 900, "radius": 1.0 },
  "itemPath": "ObstaclePillar2m",
  "mapPre": { ... },   // optional; else uses last mutator cache
  "tag": "run:..."     // optional ListTagged check
}
```
Returns `{ ok, failures: [...], found: [...] }`.

### Files
- Create: `src/NamedMacroblockStore.as`, `src/AssertPlacement.as`
- Hook optional: mutators stash last `mapPre/mapPost` in `g_LastMapDelta`
- Smoke: save → clear memory → load → place → assert

### Commit
`feat(mcp): durable named macroblocks and AssertPlacement`

---

## Cross-cutting conventions

1. **Tool style:** multi-action `Control*` tools with `action=status` default (match camera/cursor).
2. **Registration:** every tool in `IsToolName` + `CallTool` + `GetToolList` (+ schema `additionalProperties:false`).
3. **Build:** `TM_PLUGIN_SKIP_LSP=1 ./build.sh dev`; confirm `Loaded plugin 'tm-control-mcp'` without ERR after.
4. **Smoke minimum per phase:** status/tools + one happy + one failure path.
5. **Docs:** README tool table row + AGENTS one-liner + guide when conceptual.
6. **No version bump** unless Max asks.
7. **E++ first:** if export missing, land E++ export commit before MCP consumer.

---

## Suggested implementation order (calendar)

| Day | Work |
|-----|------|
| 1 | P0 complete (Readiness/Wait/call.py) |
| 1–2 | P1 structured errors (partial) |
| 2–3 | P2 provenance + RemoveByTag |
| 3–4 | P3 ControlEditMode + selects |
| 4–5 | P4 spike → inventory or skip |
| 5–6 | P5 ML result channel |
| 6–7 | P6 durable MB + AssertPlacement |

Ship P0+P2 even if P4 blocked — biggest agent pain relief.

---

## Validation matrix (live BlueBay Editor)

| Phase | Command sketch | Pass criteria |
|-------|----------------|---------------|
| P0 | `GetReadiness want=editor` | ready true, checks populated |
| P0 | `WaitUntil condition=mode equals=Menu timeoutMs=500` | timedOut true in Editor |
| P2 | SetAgentTag → PlaceItem ×3 → RemoveByTag | nbItems restored; method DeleteItems |
| P3 | ControlEditMode set FreeBlock | selection state placeMode free |
| P5 | RunManialinkScript collectMs=500 + event | results non-empty |
| P6 | Save/Load named MB → Place → AssertPlacement | ok true |

---

## Risks & open questions

| Risk | Mitigation |
|------|------------|
| Inventory node select not exported / flaky | P4 spike gate; path-place remains canonical |
| Tag match false positives on stacked items | tighter ε + idName + prefer recent lastKnownIndex |
| ML event naming collisions | prefix `McpAdHoc_` + unique pageUid |
| Structured errors break strict clients | additive fields only |
| Named MB JSON loses engine-only fields | document limits; enough for free place specs |
| `WaitUntil` blocks socket handler | already one-request-per-connection; long wait holds one client slot (cap 8) — document; keep timeout ≤ 60s |

**Open questions for Max (non-blocking defaults in plan):**
1. Default tag behavior: opt-in via `SetAgentTag` only (default empty) — **yes**.
2. Durable MB path: Openplanet data folder vs Maps/MCP — **data folder**.
3. P4 inventory select: worth E++ export if path-place covers 90%? — **spike decides**.

---

## Done definition (whole Tier A)

- [ ] P0 tools live + call.py waits
- [ ] P2 RemoveByTag cleans agent fuzz without touching untagged items
- [ ] P3 can enter free/item place modes from MCP
- [ ] P4 either shipped or explicitly deferred with spike notes in AGENTS
- [ ] P5 collectMs returns at least one event in smoke
- [ ] P6 named MB survives plugin reload
- [ ] README/AGENTS updated; no invented version
- [ ] Commits per phase on master (or review branch if Max prefers)

---

## Handoff

Plan saved for execution. Recommended start: **P0 Task P0.1** immediately (high value, low risk, no E++ changes).
