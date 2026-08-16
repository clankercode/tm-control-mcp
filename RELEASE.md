# Release process (agent walkthrough)

How to cut a **public GitHub release** of `tm-control-mcp` on **`master`**.
Follow every section in order. Do **not** invent version numbers — read
`info.toml` and confirm with the human if bumping.

## Prerequisites

- Clean `git status` on `master` (or only intentional WIP the human approved)
- Trackmania + Openplanet available for the **DEV-off compile gate**
- `gh` authenticated with push access to `clankercode/tm-control-mcp`
- Tools: `7z`, `python3`, `pytest`, `./build.sh`, optional `tm-remote-build`

```bash
cd /path/to/tm-control-mcp
git checkout master
git pull --ff-only origin master
git status
```

---

## 1. Version + changelog

1. Read current version:

   ```bash
   awk -F= '/^version/ { gsub(/[ \"]/, "", $2); print $2; exit }' info.toml
   ```

2. If cutting a new release, **bump** `info.toml` `[meta] version` (semver-ish
   `X.Y.Z` preferred for `.op` naming). Letter suffixes are manual.

3. Update `CHANGELOG.md`:
   - New `## [X.Y.Z] — YYYY-MM-DD` section at top
   - Summarize user-visible tools/fixes; link PRs if any
   - Move items out of “Unreleased” if present

4. Commit on `master`:

   ```bash
   git add info.toml CHANGELOG.md
   git commit -m "release: X.Y.Z"
   ```

---

## 2. Mandatory: DEV-off compile + reload gate

Public/release builds must **not** rely on `defines = ["DEV"]`.
`./build.sh dev` injects DEV into the staged Openplanet folder plugin — that is
for day-to-day development only.

**Always run this before tagging a release:**

```bash
# Stage folder plugin WITHOUT DEV defines and WITHOUT "(Dev)" name suffix,
# then reload via RemoteBuild (same as users of a release .op / non-dev folder).
TM_PLUGIN_SKIP_LSP=1 ./build.sh release-check
```

What this does:

1. rsync `src/` → `~/OpenplanetNext/Plugins/tm-control-mcp/`
2. Writes `info.toml` **without** expanding `#__DEFINES__` to `DEV`
3. Leaves plugin display name as **TM Control MCP** (no `(Dev)`)
4. Reloads the folder plugin

**Pass criteria (all required):**

- RemoteBuild / Openplanet log shows **compile success** and **Loaded plugin**
- No script errors that prevent socket start
- Smoke:

  ```bash
  python3 tools/call.py status
  python3 tools/call.py GetMode
  python3 tools/call.py ListPlugins '{"query":"tm-control"}'
  ```

If compile fails only with DEV absent, **stop the release** and fix before tagging.

Restore dev staging afterward if you continue coding:

```bash
TM_PLUGIN_SKIP_LSP=1 ./build.sh dev
```

---

## 3. Automated tests (no game)

```bash
python3 -m pytest tests/test_call_wait.py -q
```

CI runs the wait-helper unit tests on push (see `.github/workflows/ci.yml`).

### Optional live smoke (game required)

```bash
python3 tools/smoke_tag_cleanup.py
# readiness → SetAgentTag → place item → AssertPlacement → RemoveByTag
```

---

## 4. Build the `.op` artifact

```bash
./build.sh release
# → tm-control-mcp-<version>.op
ls -la tm-control-mcp-*.op
```

Notes:

- Package includes `src/*`, `info.toml`, `README.md` (no DEV define injection)
- `*.op` is gitignored — upload as a **release asset**, do not commit
- Optionally also zip sources; the `.op` is the primary install artifact

Sanity: ensure the packed `info.toml` still has `#__DEFINES__` commented (no
`defines = ["DEV"]`).

```bash
7z x -so tm-control-mcp-*.op info.toml | cat
```

---

## 5. Push `master`

```bash
git push origin master
```

Wait for CI green on the release commit.

---

## 6. Tag + GitHub Release (manual notes + assets)

**Do not** rely solely on auto-generated notes. Write a real changelog body.

```bash
VERSION="$(awk -F= '/^version/ { gsub(/[ \"]/, "", $2); print $2; exit }' info.toml)"
TAG="v${VERSION}"

# Annotated tag on the release commit
git tag -a "$TAG" -m "tm-control-mcp $VERSION"
git push origin "$TAG"
```

### Create the release with `gh` (recommended flow)

1. Draft notes from CHANGELOG (edit heavily):

   ```bash
   # Extract section for this version into /tmp/release-notes.md and edit
   $EDITOR /tmp/release-notes.md
   ```

2. Recommended note structure:

   ```markdown
   ## tm-control-mcp vX.Y.Z

   ### Install
   - Openplanet → install `.op` asset, **or** folder-plugin per README
   - Requires **Editor++** + **MLHook**

   ### Highlights
   - … 3–8 bullets from CHANGELOG …

   ### Artifacts
   - `tm-control-mcp-X.Y.Z.op` — Openplanet plugin package (no DEV defines)

   ### Security
   - Localhost JSON socket, **no auth** — see SECURITY.md
   - Keep Socket Host at 127.0.0.1

   ### Full changelog
   See CHANGELOG.md entry for X.Y.Z
   ```

3. Publish:

   ```bash
   gh release create "$TAG" \
     --title "v${VERSION}" \
     --notes-file /tmp/release-notes.md \
     "./tm-control-mcp-${VERSION}.op"
   ```

4. If you need to fix notes/assets after publish:

   ```bash
   gh release edit "$TAG" --notes-file /tmp/release-notes.md
   gh release upload "$TAG" "./tm-control-mcp-${VERSION}.op" --clobber
   ```

### Manual UI alternative

GitHub → Releases → Draft new release → choose tag → **paste edited notes** →
attach `.op` → Publish.

---

## 7. Post-release checks

- [ ] Release page shows correct tag, notes, and `.op` asset
- [ ] Download `.op` in a clean path and confirm size > 0
- [ ] `gh release view "$TAG"`
- [ ] Optional: announce / Openplanet site upload (human decision)
- [ ] Restore local dev plugin if needed: `TM_PLUGIN_SKIP_LSP=1 ./build.sh dev`

---

## 8. GitHub license UI note

Dual **Unlicense + CC0** is intentional. GitHub’s license detector often shows
**Other** — that is expected. Source of truth is `LICENSE`, `UNLICENSE`, `CC0-1.0`.

---

## 9. Optional: Openplanet site listing

In-client install via [openplanet.dev](https://openplanet.dev/) is a **human** step
(site account, plugin page, signed package rules). Not required for GitHub `.op`
distribution.

Checklist when you do publish there:

1. Create/update plugin page; set name **TM Control MCP**, category Development
2. Dependencies: Editor++, MLHook (versions as in README)
3. Upload the same `.op` attached to the GitHub release (no DEV defines)
4. Note localhost socket + no-auth in the site description (link SECURITY.md)
5. After approval, record `siteid` in docs/README if useful for `Meta::GetPluginFromSiteID`

---

## Quick checklist (copy/paste)

```text
[ ] version bumped in info.toml (if needed)
[ ] CHANGELOG.md updated
[ ] commit on master
[ ] ./build.sh release-check   # DEV-off compile + reload MUST be green
[ ] pytest tests/test_call_wait.py
[ ] live smoke status/GetMode
[ ] ./build.sh release → .op
[ ] PUSH MASTER (never local-only releases)
[ ] git tag vX.Y.Z && push tag
[ ] gh release create with HAND-WRITTEN notes + .op asset
[ ] verify release page
```

## Releaser tooling

There is also a generic version-bump/tag helper: [`op-plugin-releaser`](../../op-plugin-releaser)
(`op-releaser.py`, `click`-based; `release patch|minor|major`). As of its `48b6fa3` commit it
supports **both flows**:

- **plugin mode (default)** — historical bulk `tm-*` flow: tags `X.Y.Z` (bare), commits the
  built `.op` into git, pushes branch + tag.
- **app mode (`--app`)** — this repo's flow: tags **`vX.Y.Z`**, keeps the `.op` out of git,
  creates the GitHub release via `gh release create` (`--notes` / `--notes-file` / `--draft`),
  pushes branch + tag. Both modes always push — local-only releases are not supported.

For this repo the releaser can automate the mechanical steps, but it does **not** run the
DEV-off `release-check` gate, pytest, live smoke, or CHANGELOG editing — those remain manual
per the checklist above. Prefer running the full checklist by hand; the releaser's
`--app --skip-build` mode can substitute for steps 1/5/6 (bump+commit, push, tag, GH release)
if you've already built the `.op`.

## What not to do

- Do not tag if DEV-off compile fails
- Do not ship only auto-generated GH notes without editing
- Do not commit `.op` / `.zip` into git
- Do not bind the control socket off localhost in docs/examples
- Do not disable/unload the MCP plugin via automation during release smoke
- Do not finish a release without pushing master + tag and creating the GitHub release
