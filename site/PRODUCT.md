# PRODUCT — tm-control-mcp project site

Not deployed (`*.md` is excluded by `tools/build_site.py`).

## Subject

`tm-control-mcp` is an **Openplanet plugin** for **Trackmania**. It opens a
**localhost JSON TCP socket** (`127.0.0.1:30006` by default) and exposes the map
editor, main menu, race/play state and Openplanet itself as named tools. It is
**not** a standalone MCP HTTP server: one newline-terminated JSON request per TCP
connection, one JSON reply, socket closes. Clients are coding agents, MCP-style
wrappers and Python scripts (`tools/call.py` ships in the repo).

Sources of truth (read directly, 2026-10-19): `README.md`, `CHANGELOG.md`,
`SECURITY.md`, `info.toml`, `src/McpTools.as` (`MakeTool` registrations),
`src/Protocol.as` (routes), `src/EditorOptional.as` (E++ tools moved to pack),
`docs/tool-packs.md`, `docs/pack-updates.md`, `PACKLIST.md`, GitHub repo
descriptions of the five packs.

Corrections vs. stale README prose, applied on the site:

- Editor++ placement, named macroblocks, provenance tags (`RemoveByTag`) and
  inventory control moved to the **tm-mcp-pack-epp** tool pack in 0.3.0; the old
  builtin names return `moved_to_pack`. The site credits those features to the pack.
- Hard dependencies are **MLHook** and **MLFeedRaceData** (`info.toml`). Editor++
  is only needed through the E++ pack.

## Audience

1. Openplanet/Trackmania plugin authors and map-tool builders (expert, Windows or
   Proton/Linux, already run Openplanet).
2. People wiring AI coding agents to the game (know JSON/Python; may not know
   Openplanet's plugin model).
3. Tool-pack authors who need the version-file convention.

## Job

Primary: understand in one screen what the bridge is and how a client talks to it,
then install it. Secondary (ranked): see what it controls; learn the wire protocol;
find tool packs; adopt the pack update/version convention; understand the safety
model (no auth, localhost only).

## Real content

- Socket `127.0.0.1:30006`; routes `status`, `tools`, `call` (tool names also work as routes).
- Envelope `{"ok":true,"route":"call","data":{"tool":…,"result":{"success":true,"output":{…}}}}`.
- Structured errors `code`, `retryable`, `requiredMode`, `hint`.
- Install: `.op` from GitHub releases, or `./build.sh dev` from a clone.
- Latest stable version: `./latest-version.txt` (written by the Pages build, e.g. `0.4.0`).
- Packs: E++, Ghosts++, Visual, MLHook, Map Together (descriptions from GitHub).

No tool counts or activity numbers are shown: counts drift and the README count is stale.

## Constraints

- Static files only, no runtime dependencies, no network fonts/CDNs.
- Deploys with `latest-version.txt` in one GitHub Pages artifact at
  `https://clankercode.github.io/tm-control-mcp/`.
- Footer credit (clankercode rule): "Created by Max Kaye (XertroV) + AI", linked to https://xk.io.
- Spell **Trackmania** and **Openplanet** exactly.

## Success conditions

- Visitor can say what it is, what it is not (no auth, not an HTTP server), and copy a working install/verify command.
- Latest version shown when `latest-version.txt` is reachable; page degrades cleanly when not (file://, 404).
- Readable at 320px; keyboard-complete; both moods (themes); reduced motion respected.

## Vocabulary

bridge, socket, tool, route, tool pack, pack id (`packId.FuncName`), Openplanet,
Trackmania, Editor++ (E++), MLHook, MLFeedRaceData, `.op` package, latest-version file.
