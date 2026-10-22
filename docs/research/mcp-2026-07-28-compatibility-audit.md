# MCP 2026-07-28 compatibility and dynamic-tools audit

**Audited 23 October 2026 (Australia/Sydney).** Repository commit: `aeee3102d10d96ec61062d9589e5584a488b90e5`. Research and audit only: no implementation, plugin reloads, pack changes, or game-state mutations. Four subagents independently covered the specification, wire protocol, registry lifecycle, and coding clients; the coordinator ran the read-only runtime checks and integrated the findings.

## Findings at a glance

1. **Your version is correct: `2026-07-28` is the current stable MCP revision.** The wire spelling uses hyphens. The official release is neither draft nor prerelease; its tag points to `5f5440bb26a62e2cf3440b92da5a667efa03b267`. The current draft is not a newer released version. [M1] [M2]
2. **The endpoint this repository provides is not currently an MCP endpoint.** It is a useful custom JSON/TCP backend with an Anthropic-shaped tool catalog. It needs an MCP adapter before standard MCP clients can connect. No adapter was found in this repository or the bounded sibling/configuration search described below.
3. **Dynamic tool packs already work inside the backend.** Registration/removal updates schemas and invalidates an internal catalog cache. What is missing is a reliable external contract for detecting changes and refreshing agents. There are also concrete stale-cache and teardown bugs to fix.
4. **July 2026 requires more than the old `initialize` and `list_changed` recipe.** It uses per-request metadata, `server/discover`, mandatory cache hints, and explicit `subscriptions/listen` streams. Legacy clients require a separately supported path. [M3]–[M7]
5. **Coding clients differ materially.** Claude Code documents live updates and modern MCP. VS Code's inspected workbench updates schemas but still uses a legacy revision. Latest released Codex 0.163.0 only logs tool-list-change notifications; newer unreleased source adds refresh behind a disabled experimental flag. A conformant server alone cannot guarantee that every agent reloads an already known tool. [C1]–[C7]
6. **Recommended direction:** repair registry freshness, expose coherent catalog identity, and add a standalone SDK-based stdio MCP adapter supporting modern and required legacy revisions. Then prove additions, removals, and same-name schema changes in actual target clients. Add search, resources, richer results, and long-operation features in subsequent bounded slices.

## What was actually verified

| Evidence | Result |
|---|---|
| Running backend | `TM Control MCP (Dev)`, version `0.4.0`, `127.0.0.1:30006` |
| Staged source | All **42** AngelScript files match this checkout byte-for-byte; staged metadata enables `DEV`. This is a disk comparison, not an independent in-memory code digest. |
| Live native requests | `status`, `tools`, `ListToolPacks`, `ListGuides`, and `GetMode` succeed. |
| Live tool catalog | **278 unique tools:** 105 builtins; Dips 15; DipsEditor 13; MLHook 15; E++ 105; TitlePack 12; Visual 13. Six enabled packs. |
| Catalog size/stability | **131,994 wire bytes**; three subsequent reads returned the same descriptor hash. This does not measure model tokens or establish a performance budget. |
| Schema definitions | All **278** pass Draft 2020-12 schema syntax checks and declare object input roots. All captured names satisfy MCP's recommended syntax. |
| MCP Tool shape | All 278 native descriptors fail the official Tool definition because they lack `inputSchema`; all 278 pass after projecting `input_schema` to `inputSchema` and retaining supported fields. This validates the projection, not an adapter. |
| Modern protocol probes | Valid metadata-bearing `server/discover` and `tools/list` requests both return a native `unknown route` envelope. |
| Legacy protocol probes | String-ID `initialize`/`tools/list` requests return native `unknown route` envelopes. Numeric-ID probes close without a parseable reply; the exact exception was not established. |
| Existing read-only live framing tests | **6 passed**: large requests, delayed fragments, split UTF-8, and legacy EOF framing. |
| Existing offline tests | **171 passed**, covering pack infrastructure, update policy, build-state restoration, preserved registration, FID packs, and wait helpers. Most registry tests are static checks; these do not prove live lifecycle transitions. |

The first runtime capture was `2026-10-22T14:19:06.654933+00:00`, corresponding to 23 October in Sydney. Modern probes were captured at `2026-10-22T14:22:35.007928+00:00`. Raw receipts and the four research reports are in `/tmp/tm-mcp-audit-20261023-Sq0wW8/`. The catalog's canonicalized descriptor SHA-256 is `652fd27cb2419f02c43c0c888dacd7bf8fe9676c2cd24f6bc8c233f07c818fcb`.

This audit covers protocol interoperability and tool-discovery architecture. It does not certify the semantics of every game operation, test a release build, or claim that an actual coding agent completed an MCP session against an adapter that does not yet exist.

## 1. The protocol boundary

The native request path is:

`Main → ServerLoop → HandleClientInner → ReadRequestPayload → HandlePayload → HandleRequest → HandleCall → ValidateToolInput → CallTool → worker dispatch → builtin/pack handler`.

The socket accepts one JSON object per connection, replies once, and closes. Its routes are `status`, `recover`, `tools`, `call`, or a tool name. It uses `route`, `tool`, and `input`, not JSON-RPC `method` and `params`. Replies use `ok`, `id`, `route`, `error`, and `data`. Native IDs are coerced to strings. There is no JSON-RPC response envelope, MCP discovery, version handling, or MCP notification channel. See [Protocol.as](../../src/Protocol.as):62–150 and [Server.as](../../src/Server.as):231–299.

The exported catalog explicitly describes itself as Anthropic tool format: `{name, description, input_schema, pack?}`. See [TmMcp_Export.as](../../src/TmMcp_Export.as):22–26 and [McpTools.as](../../src/McpTools.as):1398–1405. The sibling `tm-agent` forwards this catalog directly to provider calls; it is not an MCP adapter (`../tm-agent/src/ToolAssembler.as:36–47`). The Python `call.py` CLI is also a native one-shot client, not an MCP stdio process.

**TCP itself is not forbidden by MCP:** custom transports are allowed if they preserve MCP's JSON-RPC messages and semantics. The incompatibility here is the application protocol, not the mere use of TCP. A raw TCP URL is also not one of the standard stdio/HTTP configurations offered by the clients researched. [M3] [M8]

The adapter search covered this repository, relevant Openplanet siblings (`tm-agent`, `tm-mcptm`, `tm-aiapi`, tool packs and plugin skills), ancestor MCP configuration locations, and MCP entries in the existing Codex, Claude and OpenCode configuration files. No relevant adapter was found. This is not a claim that no adapter exists anywhere else or remotely.

### Modern versus legacy MCP

| Area | MCP 2026-07-28 | Legacy client support |
|---|---|---|
| Opening | No initialization handshake; server **MUST** implement `server/discover`. | `initialize` followed by `notifications/initialized`. |
| Request context | Every request **MUST** carry `params._meta["io.modelcontextprotocol/protocolVersion"]` and `params._meta["io.modelcontextprotocol/clientCapabilities"]`. | Version/capabilities negotiated at initialization. |
| Identity | Namespaced client/server implementation info is **SHOULD**, not mandatory authentication identity. | Client/server info appears in initialization. |
| Results | **MUST** include `resultType`, normally `"complete"`. | Earlier results need not contain it. |
| Discovery/list caching | Completed discovery and list results **MUST** include `ttlMs` and `cacheScope`; resource reads also have the cache contract. | No July cache-hint contract. |
| List changes | Client explicitly opens `subscriptions/listen`; server acknowledges the subscription and correlates notifications to it. | Change notifications on the legacy transport/connection. |
| HTTP | Request-scoped POST/JSON/SSE; no modern session ID or separate GET notification endpoint. Required version/method/name headers must match the body. | Session/GET behavior depends on the earlier transport revision. |
| Server requests | Additional-input interactions use multi-round-trip results (`input_required`). | Earlier server-initiated request model. |

Sources: [M3]–[M9]. Missing modern metadata is `-32602`; unsupported versions use `-32022` with supported/requested version data. Do not just echo an arbitrary client version. Do not infer capabilities or protocol era from a client product name.

Modern statelessness forbids depending on earlier connection context for version/capabilities. It does not prohibit shared application state such as the game world. Explicit operation IDs, ownership tags and registry identity remain useful application concepts.

### Direct compatibility verdict

| Surface | Current status | Importance |
|---|---|---|
| JSON-RPC, versioning, discovery, standard transport | Missing | Blocks direct MCP integration. |
| Standard `tools/list` and `tools/call` envelopes | Missing; native equivalents exist | Blocks integration until translated. |
| Valid reusable input schemas | Present for all captured tools | Strong starting point; validation enforcement still incomplete. |
| MCP content/results and error mapping | Missing | Adapter must implement them. |
| Dynamic registration/removal | Present internally | Needs correctness fixes and external invalidation. |
| Change subscriptions and modern cache hints | Missing | Required for the proposed refresh feature; cache hints are mandatory for modern lists. |
| Pagination | Missing | Optional; a complete one-page list is valid. |
| Annotations/output schemas/resources/prompts | Missing as MCP features | Optional improvements, not independent conformance blockers. |
| Progress/Tasks/MRTR | Native waits/helpers are not these features | Optional; do not claim support by analogy. |

## 2. Concrete implementation findings

### F1 — A warmed catalog can keep advertising a dead pack

**Confirmed by source; the state transition was not exercised live.** `GetToolList()` returns its cached value before checking owner liveness. `SweepDeadPacks()` runs inside `AppendPackTools()`, which is reached on a rebuild. With a warm cache, an unload/disable that misses cleanup can leave repeated `route=tools` reads stale. `ListToolPacks`, the settings UI, another registry mutation, or pack dispatch can trigger a sweep and appear to fix it. Ordinary builtin calls need not do so.

Evidence: [McpTools.as](../../src/McpTools.as):1267–1278,1394; [ToolPacks.as](../../src/ToolPacks.as):49–68,251–268; [Main.as](../../src/Main.as):1–9.

**Change:** reconcile owner liveness before accepting a catalog-cache hit, or provide a reliable bounded lifecycle watcher. Removal must invalidate both catalog and schema registry. A future adapter polling only the current `tools` route would inherit this defect.

### F2 — Strict CLI validation can use stale or unrelated schemas for 24 hours

**Confirmed by source and a mocked call to the production function.** `load_schemas(host, port, ...)` can return the same `~/.cache/tm-control-mcp/schemas.json` for any endpoint within its 24-hour TTL. It does not key by host/port, bridge instance, or registry revision. Strict mode can reject a newly added tool/parameter before contacting the bridge. Fetching `call.py tools` does not itself refresh this strict-mode cache.

Evidence: [call.py](../../tools/call.py):140–180,627–654. The offline demonstration returned cached `fixture.Echo(text)` for a different endpoint with zero network calls, then rejected a valid updated `message` argument.

**Current workaround:** `--refresh-schemas` implies strict validation and refetches. Normal calls do not use this strict-cache gate. **Change:** endpoint/instance-scoped, revision-aware caches; one refresh before reporting a cache-derived preflight failure. Do not retry a mutation that may already have executed.

### F3 — Advertised JSON Schema and enforced validation are different contracts

**Confirmed by source and offline examples.** Registration checks that a schema parses as a JSON object, not that it is a valid schema with the supported dialect/object root. The validator checks a subset of top-level keys and primitive types. It ignores nested constraints, enums, compositions and bounds; skips union types; accepts fractional values for integers; and rejects unknown keys even when a schema allows additional properties. Imported `CallTool` bypasses the generic validator applied by the socket wrapper.

Evidence: [ToolPacks.as](../../src/ToolPacks.as):136–149; [ToolInputValidation.as](../../src/ToolInputValidation.as):84–215; [Protocol.as](../../src/Protocol.as):117–126; [ToolCalls.as](../../src/ToolCalls.as):94–148; [call.py](../../tools/call.py):201–237.

Actual saved schemas include enum, array-item and numeric-bound constraints. The production Python validator accepted these inputs offline although Draft 2020-12 rejects them:

| Tool | Invalid argument accepted by the shallow validator |
|---|---|
| `OpenMapInEditor` | `{"path":"anything","waitMs":1.5}` |
| `ComputeShadows` | `{"quality":true}` |
| `ControlEditorScriptPlugins` | `{"action":"definitely-invalid"}` |

No such calls were sent to the game; handlers may reject them later. All current captured schema definitions are valid. The finding is about enforcement and future admission, not a claim that those tools necessarily mutate on bad input.

**Change:** validate schema definitions and arguments separately, use a real Draft 2020-12 validator in the adapter, and establish a consistent validation contract for native/imported entry points. Bound schema work; do not automatically fetch network `$ref`s, which modern MCP forbids by default. [M3]

### F4 — Unregister-by-plugin-ID does not always remove all owned packs

**Confirmed source/documentation mismatch.** The guide promises that passing a plugin ID removes every pack owned by it. The implementation only takes that path if no exact pack ID matches. A plugin owning default `Owner` plus custom `Extra` can remove only `Owner`; a foreign pack whose prefix equals the caller's plugin ID can cause `pack_not_owner` instead of removing the caller's other packs.

Evidence: [tool-packs.md](../tool-packs.md):55; [ToolPacks.as](../../src/ToolPacks.as):192–214.

Ownership checks correctly prevent removing the foreign pack; this is not an authorization bypass. **Change:** make exact-pack removal and remove-all-owned explicit operations, or document and implement unambiguous owner-ID precedence. Test multiple prefixes and collision cases.

### F5 — Catalog ownership and replacement need a stronger boundary

**Confirmed:** `GetToolList()` exports the mutable cached `Json::Value@` directly, so an in-process consumer can corrupt later listings without updating the registry. Return a protected snapshot or defensive copy at the public boundary. [McpTools.as](../../src/McpTools.as):1269–1278; [TmMcp_Export.as](../../src/TmMcp_Export.as):26.

**Confirmed:** same-name schema replacement is remove-then-register. Individual registration stages data and rolls back ordinary insertion failure, but replacing a whole existing pack is not atomic; failure after removal leaves it unavailable. There is no public catalog revision/hash or change subscription. Release versions in `ListToolPacks` are not schema fingerprints. [ToolPacks.as](../../src/ToolPacks.as):82–165,192–214; [McpTools.as](../../src/McpTools.as):1267.

**Unproven lifecycle risk:** the registry tracks owner ID and callback, not a pack incarnation. A reload during yielded dispatch needs testing for stale callbacks, admission into a replacement implementation, and terminal results. Existing worker monitoring and timeout quarantine are valuable safeguards, but do not establish pack-generation safety. [ToolPacks.as](../../src/ToolPacks.as):4–10,59–65,217–248; [ToolCalls.as](../../src/ToolCalls.as):47–68.

**Change:** separate bridge-instance identity, catalog revision/descriptor hash, and pack incarnation. Validate a replacement before swapping it; define treatment of in-flight old calls. A metadata revision is not a cancellation mechanism.

### F6 — Error/results translation must inspect both native layers

Native `ok:true` means the route completed; its nested tool result may have `success:false`. Unknown tools can also be nested errors. `call.py` exits zero for received replies, including failed tools, so shell exit status is not sufficient adapter logic. `GetResult` has another native response shape requiring explicit normalization.

Evidence: [Protocol.as](../../src/Protocol.as):121–150; [McpTools.as](../../src/McpTools.as):28–53; [call.py](../../tools/call.py):731–748; [AsyncDispatchLocal.as](../../src/AsyncDispatchLocal.as):36–47.

**Change:** protocol failures use appropriate JSON-RPC errors; a known tool's validation/business/execution failure becomes a tool result with `isError:true`, preserving `code`, `retryable`, mode, hint and partial-outcome information. Successful results need `content`; structured output should also be available where useful. For modern MCP add `resultType:"complete"`. Unknown tools use the protocol-error path described in the tools spec. [M3] [M4]

Screenshots currently return path/metadata, not image content. An agent receiving a path has not necessarily received the image. Add verified, bounded image/resource delivery separately. Open issue [#19](https://github.com/clankercode/tm-control-mcp/issues/19) already records stale screenshot-detection concerns; a wrapper must not amplify an unverified file into a claimed fresh image.

### F7 — Documentation and metadata limit discovery quality

- The native catalog has only name, description, input schema and optional pack ID. No annotations, output schemas, titles, icons or pack-owned guide registration are available through the builder. These are optional MCP features, but useful next additions. [ToolPackShared.as](../../src/ToolPackShared.as):5–42.
- Local names only need to be nonempty and lack `.`; default plugin IDs bypass the custom-prefix character check. All observed names are fine, but future invalid/oversized names can be admitted. Validate the complete public name against the recommended 1–128 character form. Dotted prefixes themselves are valid MCP names. [ToolPacks.as](../../src/ToolPacks.as):22–38,92–132; [M4].
- `agent-cleanup` still teaches unqualified E++ names that now return `moved_to_pack`; the migration guide exists but does not repair the earlier recipe. [Guides.as](../../src/Guides.as):273,404; [EditorOptional.as](../../src/EditorOptional.as):26,118.
- The old [schema-registry research note](tool-pack-schema-registry.md) claims runtime registration does not exist. It is historical, not a current compatibility assessment.
- `SECURITY.md` says traces contain full payloads, while current tracing records byte counts and bounded lifecycle metadata. Update that statement rather than carrying it into adapter docs. [SECURITY.md](../../SECURITY.md):63–65; [RequestTrace.as](../../src/RequestTrace.as):1–2,44–47.

### Existing strengths worth preserving

Registration authenticates the actual calling plugin, rejects duplicate/reserved pack IDs and duplicate local names, requires a dispatch callback, stages before publication, and removes schemas on normal unregister. Pack dispatch checks owner liveness and catches ordinary exceptions. The fixture re-registers on enable and cleans up on disable/destroy. Provider build tooling snapshots and restores registered dependents, with offline coverage. Native framing has bounded reads, a 16 MiB request limit and explicit errors. The bridge tracks in-flight workers and quarantines timed-out workers that may still execute.

These are useful foundations. They should remain behind an adapter, with targeted repairs, rather than be discarded in a protocol rewrite.

## 3. How dynamically changed tools should reach an agent

There are five separate steps:

1. **Availability:** the plugin registers/removes/replaces a pack and the native registry publishes the current callable set.
2. **Detection:** the adapter sees a new coherent descriptor snapshot, including schema/description changes under unchanged names.
3. **Invalidation:** the adapter emits the correct era's change signal; modern clients must have requested a subscription.
4. **Host refresh:** the client fetches the updated catalog and rebuilds its schema/search cache.
5. **Model exposure:** a subsequent model request receives the new definition, or tool search loads it when needed.

An already-sent model request cannot be retroactively rewritten. A successful notification is evidence of step 3, not proof of steps 4–5.

```mermaid
sequenceDiagram
    participant H as Coding-agent host
    participant A as MCP adapter
    participant B as Native bridge / packs
    H->>A: server/discover (2026 request metadata)
    A-->>H: capabilities, versions, cache hints
    H->>A: tools/list
    A-->>H: complete current descriptors, cache hints
    H->>A: subscriptions/listen (toolsListChanged)
    A-->>H: notifications/subscriptions/acknowledged
    B->>B: Register / remove / replace pack
    A->>B: Observe new revision; fetch coherent catalog
    A->>A: Publish updated descriptors
    A-->>H: notifications/tools/list_changed (subscription ID)
    H->>A: tools/list
    A-->>H: Updated schemas
    H->>H: Refresh search/index; expose on next model request
```

For legacy clients, initialization and legacy notification delivery replace the modern discovery/subscription opening. The native backend need not speak either wire protocol.

### Catalog identity and cache policy

Proposed native fields such as `{instanceId, catalogRevision, descriptorHash}` are application design, **not** MCP-standard fields. A useful contract would:

- Reconcile dead owners before declaring a snapshot current; publish registration/replacement atomically.
- Hash canonical, deterministically ordered full descriptors, including schema, description and any future annotations/output schema. Count/name-only comparisons miss changed tools.
- Keep pack-incarnation/in-flight-call identity separate from descriptor identity. Identical schemas do not prove callbacks belong to the same loaded module.
- Expose a cheap revision check so the adapter need not repeatedly transfer the entire 132 KB catalog. Polling can be an initial fallback, with bounded work/backoff and no false claim of push from the plugin.
- Publish first, then notify. Coalesce bursts; never notify clients of a snapshot that cannot yet be fetched.
- Treat stale calls explicitly. Prefer additive changes; for breaking changes use a versioned tool or compatibility period. Reject outdated arguments clearly without silently dispatching to a different tool.

Modern cache hints remain necessary even with an application revision. `ttlMs:0` means stale on next access; it does not force hosts to poll. Notifications invalidate otherwise fresh caches. `cacheScope` must reflect whether sharing is safe; private caches must not cross authorization contexts. TTL-driven background polling, if used, needs jitter/backoff. Cache pages consistently; stale cursors should cause a fresh listing. [M7]

### Search and deferred loading

MCP standardizes `tools/list`, not `tools/search`, `tools/get`, or a method that installs a definition into an LLM. Pagination reduces response size, not necessarily model context. Tool packs are this application's grouping mechanism, not a standard MCP primitive.

The official client guidance describes keeping a complete catalog outside model context and exposing a search/inspect/execute path. That is **host implementation guidance**, not additional core RPC methods. Claude/OpenAI deferred-loading knobs and returned tool references belong to their host/API integrations. A server cannot force every host to honor them. [M10] [C1] [C8]

For this project:

- Keep standard listing complete for the exposed configuration; let capable hosts index/defer it.
- Add optional ordinary `SearchTools`/`DescribeTool` operations for scripts and generic agents. Return names, intent, pack and schema/revision. Returning schema text does not itself register a native function in the caller's host.
- Put distinguishing pack and capability words early in descriptions; make server instructions point to readiness, qualified names, guides and non-retryable/uncertain outcomes.
- Do not implement hidden per-connection pack activation that changes later `tools/list` results. Modern MCP forbids that connection-dependent catalog behavior. Explicitly configured server subsets can be a fallback for constrained clients. [M4]
- Preserve `packId.FuncName` as the canonical dispatch identity. Hosts may map it to different model-facing names; verify collisions and retain a reversible mapping if aliases become necessary.

## 4. Coding-agent compatibility: documented versus proved

These are live first-party documentation/source findings, **not executed client tests against this project**. Source revisions are pinned below.

| Client | Protocol support examined | Dynamic update behavior | Practical implication |
|---|---|---|---|
| **Codex 0.163.0**, latest released tag retrieved | Default legacy preference `2025-06-18`; modern `2026-07-28` is experimental/off by default. Modern stdio has an additional per-server opt-in. | Released handler only logs `tools/list_changed`; discovery reads its stored catalog. | Do not promise hot additions/schema replacement on released defaults. Tool search can search stale descriptors. Test a fresh connection/session and verify the actual schema. |
| **Newer Codex main**, `9a8a85bc539325f2819dd0717f88b6ba6286495e` | Modern protocol still experimentally gated. | Adds `mcp_tool_list_changed`, also disabled/experimental; refreshes notified catalogs before new bindings and reconstructs changed handlers. | Promising test target, not a released/default guarantee. Record both independent feature gates. |
| **Claude Code**, current docs; release `v2.1.308` retrieved | v2 MCP runtime documents `2026-07-28`; runtime/version/server-specific exceptions remain possible. | Interactive refreshes tools/prompts/resources; headless `-p` and Agent SDK refresh tools. v2 maintains subscription streams, with retry limits; failed refresh retains old data. Tool search is on by default, subject to provider/configuration. | Strongest documented fit. Test same-name schema replacement after a tool was already searched/loaded, and stream loss. `/mcp` reconnect is documented recovery. |
| **VS Code 1.143.0 workbench/Local** | Inspected client uses legacy `2025-11-25`; modern subscriptions not established. | Notification triggers listing, changed schemas re-register language-model tools, removed tools are disposed, and pending refresh is awaited after a tool call. | Useful legacy target. Verify actual subsequent model definitions, not just the tools panel. |
| **VS Code Copilot harness/runtime** | Separate from the inspected workbench path; current modern support not established here. | Product docs distinguish harnesses. | Test separately; do not inherit the Local verdict automatically. |

Sources: [C1]–[C7]. All three client families document stdio and HTTP integration; legacy SSE details vary. Current VS Code docs warn about requests with more than **128 enabled tools** and describe selection/virtual-tool controls. That is a host constraint, **not an MCP limit**, and makes this 278-tool catalog a necessary scaling test. [C7]

Codex's released modern-stdio implementation checks a configured `CODEX_MCP_PROTOCOL_VERSION=2026-07-28` marker in addition to its experimental protocol setting. This is source evidence explaining why implementing the server is insufficient; it is not a request to change local client settings in this audit. Codex `/mcp` is documented as an inventory view; do not invent a universal `/mcp reload` command. Its App Server configuration-reload API is separate and may reuse unchanged connections. [C2] [C3]

Claude's v2 stream retries can pause after repeated closures; reconnecting can be necessary. The docs establish later-request availability for newly connected servers, but do not explicitly guarantee every already-loaded same-name schema updates at every point within a turn. VS Code documents `MCP: Reset Cached Tools` and server restart/stop/start. [C1] [C6]

Dotted names are allowed by MCP. Inspected Codex and VS Code keep the original wire name while normalizing model-facing names; their algorithms differ. Claude's exact normalization was not established. Test dotted/underscore collisions instead of renaming all existing packs pre-emptively. [M4] [C3] [C6]

## 5. Features worth adopting, and features to defer

| Feature | Recommendation | Purpose / condition |
|---|---|---|
| Standard tools, results, capability/version handling | **First delivery** | Establish real MCP interoperability. |
| Modern cache hints + change subscriptions; legacy notifications | **First dynamic delivery** | Make additions/removals/schema changes observable. Advertise `listChanged` only when implemented. |
| Deterministic catalog, optional pagination, host discovery guidance | **Early** | Stable indexing and complete discovery at 278+ tools. One page is acceptable initially. |
| Tool annotations | **Early, accurately** | Identify read-only/destructive/idempotent/open-world behavior. Mixed-action tools need conservative hints; hints are not authorization. |
| Structured results + accurate output schemas | **Early, incrementally** | Preserve machine-readable state, errors and partial outcomes. An advertised output schema must match actual structured results. Modern structured content may be any JSON value; respect older clients' constraints. |
| Guides as resources/resource templates | **Useful next slice** | Standard on-demand documentation. Keep existing guide tools for native callers; add owner-aware pack guides if needed. Cache/read/subscription rules apply when advertised. |
| Screenshot image/resource content | **Useful next slice** | Let agents actually see fresh screenshots; verify production, size/MIME and client rendering. Text paths alone are insufficient. |
| Workflow prompts | **Optional** | Discoverable map-editing/readiness/cleanup recipes, if target clients expose prompts. They do not automatically execute themselves. |
| Progress + cooperative cancellation | **Useful for long operations** | Report actual progress and stop supported queued/cooperative work. Closing a socket is not proof a game mutation stopped. |
| Tasks extension | **Defer until a concrete supported client/use case** | Modern Tasks requires durable handles and its own capability/extension contract. Native async helpers are not Tasks. |
| MRTR/elicitation | **Defer** | Add only for a real additional-input workflow and declared client support. Do not require it merely to wrap existing tools. |
| Roots, sampling, logging protocol features | **Do not add as a modernization checkbox** | Deprecated in July 2026. Existing local diagnostics can remain. |
| HTTP/OAuth / `x-mcp-header` routing | **Defer unless a named consumer needs HTTP** | Local stdio is sufficient for initial coding-client integration. If HTTP is added, implement its complete transport/Origin/header contract. |

Sources: [M3]–[M12]. Modern Tasks is optional `io.modelcontextprotocol/tasks`, with `tasks/get`, `tasks/update`, `tasks/cancel` and `resultType:"task"`; the old `tasks/list`/blocking `tasks/result` design must not be transplanted. It requires durable task creation before returning a handle. [M12]

## 6. Recommended architecture and implementation plan

### Decision

Context: preserve existing Python/in-process consumers, expose tools to standard coding clients, support dynamic descriptors, and keep protocol maintenance outside the game.

| Idea | All goals | Standard MCP | Existing native callers | Modern + required legacy clients | Dynamic descriptors |
|---|:---:|:---:|:---:|:---:|:---:|
| Relabel native TCP / configure `call.py` as MCP | Fail | Fail | Pass | Fail | Insufficient |
| Static MCP wrapper with a startup-only tool table | Fail | Possible | Pass | Possible | Fail |
| Replace native endpoint with modern-only MCP | Fail | Possible | Fail without additional compatibility | Fail for legacy clients | Possible |
| **Separate SDK adapter consuming the live registry** | **Viable design** | Possible | Pass by design | Possible | Possible |

“Possible” is an implementation obligation, not a test pass. The decisive errors reject the first three proposals; the last has no identified architectural contradiction.

**Concrete SDK route verified in this audit:** the official TypeScript v2 SDK documents July 2026 support; published `@modelcontextprotocol/server` and `@modelcontextprotocol/client` are **2.3.1**, requiring Node 20+. `serveStdio` supports legacy clients by default (`legacy:'serve'`); it selects a legacy instance when a client opens with `initialize`. The low-level `Server` supports a dynamic external registry and `fromJsonSchema` validation. The old umbrella `@modelcontextprotocol/sdk` is still on **1.32.1**—installing that package's latest tag is not the same as choosing the modern v2 line. [S1]–[S4]

This is a researched implementation option, not a dependency installation or an executed SDK integration. Pin the selected SDK and test the contract. Avoid rebuilding 278 schemas into handwritten Zod definitions; preserve the authoritative JSON Schema catalog and validate through the supported dynamic route. If choosing Python instead, verify its v2 equivalent before committing the implementation; published `mcp` was 2.3.0, but this audit did not inspect its equivalent APIs as deeply.

### Slice A — Repair freshness and define the native catalog contract

Fix F1/F2/F4, protect catalog snapshots, and define instance/revision/hash plus validate-before-swap replacement. Keep legacy native envelopes and exported consumers compatible. Extend metadata through a versioned descriptor API where possible: changing shared builder classes can require reloading the bridge and every dependent pack.

**Acceptance:** a warm catalog loses a missing-owner pack without an unrelated `ListToolPacks`; all owned prefixes disappear on owner cleanup; endpoints cannot share incorrect strict caches; schema-only/description-only updates change the descriptor identity; unchanged reads do not; failed replacement preserves the previous usable catalog or exposes a documented atomic failure state.

### Slice B — Deliver real MCP with a read-only vertical test

Add a standalone stdio adapter, a pinned v2 SDK and a thin native TCP client with bounded I/O. Modern path: per-request metadata, `server/discover`, truthful supported versions, `resultType`, cache hints, standard tools and errors. Legacy path: explicitly test **2025-06-18 and 2025-11-25**, matching the researched Codex/VS Code clients. Initially advertise only implemented tools capability.

**Acceptance:** fake-backend protocol tests plus one real client discover/list/`GetMode` round trip; number/string request IDs; no response to notifications; malformed input and backend-unavailable cases; no stdout diagnostics; full catalog preserved; schema validation before dispatch; native tools still work. Neither a renamed JSON field nor an Inspector-only schema view is this acceptance gate.

### Slice C — Prove dynamic changes end to end

Read the revised catalog contract; publish coherent updated descriptors before notifying. Implement modern subscription acknowledgment/filter/ID routing and reconnect behavior, plus legacy notifications. Detect changes to already existing descriptors, not only counts. Make TTL/scope truthful even when a client does not subscribe.

**Acceptance:** harmless fixture adds/removes a dotted tool, changes a required parameter under the same name, changes a tool already loaded by search, and updates during an active request. Capture the event, re-list, actual schema exposed on the next model request, and a successful harmless call with the new parameter. Test no subscriber, closed stream, stale cursor, backend restart and name-normalization collision. No unsupported tool should remain falsely callable.

Use Codex released/default behavior as a documented limitation test; separately test an explicitly enabled newer refresh implementation. Test Claude v2 and forced legacy, VS Code Local, and any selected Copilot harness independently. Record client version, model/provider, transport, negotiated protocol, flags and fallback/recovery procedure.

### Slice D — Improve discovery and result usability

Add concise server guidance, optional search/describe operations, accurate annotations, and output schemas for a useful subset. Repair guides and historical-doc labeling. Expose guides as resources and screenshots as real image/resource content if client tests justify those surfaces.

**Acceptance:** a client discovers the right pack/tool among 278+ entries without loading every full schema into model context; failed/partial calls remain distinguishable; annotations match observed behavior; a screenshot is freshly produced and visibly received by the client; guide examples reference currently callable names.

### Slice E — Long operations, then optional transports/extensions

Define timeout, cancellation and uncertain-outcome semantics before progress or Tasks. Native workers can continue after a frontend timeout; the bridge explicitly notes no general awaitable cancellation API. Never automatically replay an uncertain mutation. Open issue [#20](https://github.com/clankercode/tm-control-mcp/issues/20) already documents a successful 7.2-second operation exceeding the CLI's five-second default; an adapter must not blindly inherit that timeout.

**Acceptance:** a cancelled frontend stops receiving results while accurately reporting whether backend work may continue; progress comes from actual observable work and stops on completion; uncertain outcomes have a read-back/recovery path. Add Tasks only with durable state and a supported target client. Add HTTP only with its own POST/JSON/SSE, required-header, Origin, cancellation and subscription tests.

No pack unload/reload or other game mutation test was performed for this audit. Those are later implementation validation tasks, preferably beginning with a fake backend/executable registry harness and then an isolated fixture.

## 7. Validation limits and completion criteria

The existing 171 offline tests passed, but `tests/test_tool_packs.py` principally checks source tokens/files. The update-policy tests execute pure policy with shims; build restoration tests use fake helpers. They do not execute the warm-cache missed-cleanup transition, atomic schema replacement, mutable-handle corruption, multi-prefix teardown or unload-during-call behavior. `tools/verify_tool_packs.py` would install and unload a fixture, so it was deliberately not run during this research task.

The six live tests exercise the custom transport only. A future “MCP compatible” claim should require:

- A named real coding client discovering and calling through the adapter.
- Separate conformance coverage for every advertised modern/legacy revision.
- Accurate tool-result/error mapping and full schema validation.
- Demonstrated add/remove/schema-change behavior, or an explicit documented client limitation and verified refresh procedure.
- Preserved native CLI and in-process consumers.
- No claims that timeout/cancellation reverses completed or continuing game work.

Until those gates pass, the accurate description is **a native game-control backend ready to be adapted to MCP**, with the registry corrections above still required for dependable dynamic discovery.

## Primary sources

All sources were fetched during this audit on 23 October 2026 Sydney time. Versioned specification URLs refer to `2026-07-28`; canonical schema source was inspected at commit `80041ab0a139a8f4fb3adbc99f7ae9113ea59671`. MUST/SHOULD/MAY distinctions above follow those sources. Client source findings are explicitly scoped to releases/commits rather than treated as installed behavior.

- **M1:** [Official versioning](https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning), [stable release](https://github.com/modelcontextprotocol/modelcontextprotocol/releases/tag/2026-07-28).
- **M2:** [Pinned canonical schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/80041ab0a139a8f4fb3adbc99f7ae9113ea59671/schema/2026-07-28/schema.ts), [draft changelog](https://modelcontextprotocol.io/specification/draft/changelog).
- **M3:** [Base protocol and JSON Schema](https://modelcontextprotocol.io/specification/2026-07-28/basic), [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).
- **M4:** [Tools, names, errors, metadata](https://modelcontextprotocol.io/specification/2026-07-28/server/tools).
- **M5:** [Server discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover).
- **M6:** [Subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions).
- **M7:** [Caching](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching), [pagination](https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/pagination).
- **M8:** [Transports](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports), [stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio), [HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http).
- **M9:** [Legacy 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).
- **M10:** [Client discovery/scaling guidance](https://modelcontextprotocol.io/docs/2026-07-28/develop/clients/client-best-practices).
- **M11:** [July changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog), [resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources), [prompts](https://modelcontextprotocol.io/specification/2026-07-28/server/prompts), [progress](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress), [cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation), [MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr).
- **M12:** [Tasks overview](https://modelcontextprotocol.io/extensions/tasks/overview), [pinned Tasks extension](https://github.com/modelcontextprotocol/ext-tasks/blob/b3d28aceaa6d49f5f92258e3d06b61ad6f111e84/specification/2026-07-28/tasks.md).
- **C1:** [Claude Code MCP docs](https://code.claude.com/docs/en/mcp), especially client runtimes, dynamic updates, notification streams and tool search; [release v2.1.308](https://github.com/anthropics/claude-code/releases/tag/v2.1.308).
- **C2:** [Codex MCP docs](https://developers.openai.com/codex/mcp), [App Server](https://learn.chatgpt.com/docs/app-server).
- **C3:** [Codex 0.163.0 notification handler](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/rmcp-client/src/logging_client_handler.rs#L82-L92), [stored catalog](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/codex-mcp/src/connection_manager/tool_catalog.rs#L393-L401), [protocol mode](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/rmcp-client/src/protocol_mode.rs#L8-L50), [stdio opt-in](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/rmcp-client/src/rmcp_client.rs#L485-L491).
- **C4:** [Newer Codex experimental gates](https://github.com/openai/codex/blob/9a8a85bc539325f2819dd0717f88b6ba6286495e/codex-rs/features/src/lib.rs#L1601-L1617), [catalog refresh](https://github.com/openai/codex/blob/9a8a85bc539325f2819dd0717f88b6ba6286495e/codex-rs/codex-mcp/src/connection_manager.rs#L219-L243).
- **C5:** [Newer Codex changed-handler reconstruction](https://github.com/openai/codex/blob/9a8a85bc539325f2819dd0717f88b6ba6286495e/codex-rs/core/src/mcp_tool_exposure.rs#L172-L208).
- **C6:** [VS Code 1.143.0 protocol](https://github.com/microsoft/vscode/blob/1.143.0/src/vs/platform/mcp/common/modelContextProtocol.ts#L43), [notification handling](https://github.com/microsoft/vscode/blob/1.143.0/src/vs/workbench/contrib/mcp/common/mcpServerRequestHandler.ts#L374-L376), [tool registration](https://github.com/microsoft/vscode/blob/1.143.0/src/vs/workbench/contrib/mcp/common/mcpLanguageModelToolContribution.ts#L144-L192), [developer guide](https://code.visualstudio.com/api/extension-guides/ai/mcp).
- **C7:** [VS Code MCP configuration/cache reset](https://code.visualstudio.com/docs/agents/reference/mcp-configuration), [server management](https://code.visualstudio.com/docs/agents/run/manage-mcp-servers), [tool limits](https://code.visualstudio.com/docs/agents/run/tools), [harness distinctions](https://code.visualstudio.com/docs/agents/run/agent-harnesses).
- **C8:** [OpenAI tool search](https://developers.openai.com/api/docs/guides/tools-tool-search), [Anthropic tool search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool).
- **S1:** [TypeScript SDK README, pinned](https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/README.md).
- **S2:** [SDK legacy stdio support, pinned](https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/docs/serving/legacy-clients.md), [stdio entrypoint](https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/docs/serving/stdio.md).
- **S3:** [SDK dynamic/low-level server and schema validation](https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/docs/advanced/low-level-server.md).
- **S4:** Registry metadata fetched for [`@modelcontextprotocol/server`](https://registry.npmjs.org/@modelcontextprotocol/server/latest), [`@modelcontextprotocol/client`](https://registry.npmjs.org/@modelcontextprotocol/client/latest), [old umbrella SDK](https://registry.npmjs.org/@modelcontextprotocol/sdk/latest), and [Python MCP](https://pypi.org/pypi/mcp/json). These `latest` URLs are moving references; versions above record the retrieved values.

[M1]: https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning
[M2]: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/80041ab0a139a8f4fb3adbc99f7ae9113ea59671/schema/2026-07-28/schema.ts
[M3]: https://modelcontextprotocol.io/specification/2026-07-28/basic
[M4]: https://modelcontextprotocol.io/specification/2026-07-28/server/tools
[M5]: https://modelcontextprotocol.io/specification/2026-07-28/server/discover
[M6]: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions
[M7]: https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching
[M8]: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports
[M9]: https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
[M10]: https://modelcontextprotocol.io/docs/2026-07-28/develop/clients/client-best-practices
[M11]: https://modelcontextprotocol.io/specification/2026-07-28/changelog
[M12]: https://modelcontextprotocol.io/extensions/tasks/overview
[C1]: https://code.claude.com/docs/en/mcp
[C2]: https://developers.openai.com/codex/mcp
[C3]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/rmcp-client/src/logging_client_handler.rs#L82-L92
[C4]: https://github.com/openai/codex/blob/9a8a85bc539325f2819dd0717f88b6ba6286495e/codex-rs/features/src/lib.rs#L1601-L1617
[C5]: https://github.com/openai/codex/blob/9a8a85bc539325f2819dd0717f88b6ba6286495e/codex-rs/core/src/mcp_tool_exposure.rs#L172-L208
[C6]: https://github.com/microsoft/vscode/blob/1.143.0/src/vs/platform/mcp/common/modelContextProtocol.ts#L43
[C7]: https://code.visualstudio.com/docs/agents/reference/mcp-configuration
[C8]: https://developers.openai.com/api/docs/guides/tools-tool-search
[S1]: https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/README.md
[S2]: https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/docs/serving/legacy-clients.md
[S3]: https://github.com/modelcontextprotocol/typescript-sdk/blob/c05225a636c679870b65f8ca4fe83a76ea1cf113/docs/advanced/low-level-server.md
[S4]: https://registry.npmjs.org/@modelcontextprotocol/server/latest
