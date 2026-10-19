# Pack updates and the version-file convention

Tool packs are separate Openplanet plugins. They register tools through
`TmMcp::ToolPackBuilder`, and may declare a **latest-release URL** on that builder:

```angelscript
auto b = TmMcp::ToolPackBuilder("MyPack");
b.SetLatestReleaseUrl("https://YOUR-ACCOUNT.github.io/YOUR-PACK/latest-version.txt");
// b.AddTool(...), b.SetDispatch(...), then TmMcp::RegisterToolPack(b).
```

The public metadata field is `latestReleaseUrl`; the fluent setter is
`SetLatestReleaseUrl`. Set it on every builder if a plugin registers multiple
packs. Existing packs still register without it, but registration logs a warning
and discovery/settings report `missing_url`. Invalid URLs similarly warn and
report `invalid_url`; they do not disable otherwise working tools. There is no
GitHub API or HTML-scraping fallback. The declared URL is the update source.

This extends a shared Openplanet class. After upgrading the bridge, restart
Trackmania before loading rebuilt packs if Openplanet reports a shared-definition
mismatch. Load the bridge before its dependent packs.

## Version-file format

The response contains **only one version string**, optionally surrounded by
whitespace and a trailing newline:

```text
0.2.0
```

Use semantic versions (`MAJOR.MINOR.PATCH`). An optional leading `v`, prerelease
identifiers (`1.0.0-rc.2`), and build metadata (`1.0.0+build.4`) are accepted.
Version precedence follows SemVer: numeric components compare numerically,
prereleases sort below the corresponding stable release, and build metadata
does not change precedence. Invalid or unknown versions never assert an update.
Publish the latest **stable** version by default; a deliberate prerelease channel
may use its own URL.

The installed version always comes from the registering plugin's
`Meta::Plugin.Version` (`[meta] version` in its `info.toml`), including custom pack
IDs. A pack cannot override it with another claimed version.

Use a direct, public **HTTPS** URL with a lowercase DNS hostname and a file path.
Redirects, credentials, port overrides, queries, fragments, IP literals, and
percent-escaped paths are not supported. Use the canonical final URL. The URL
limit is 1,024 bytes, the response limit is 1,024 bytes, and the trimmed version
limit is 256 bytes. Do not return JSON, HTML, a release URL, or explanatory text.

## Polite background checks

One coroutine owns all requests; API calls, registration, and rendering never
wait for HTTP. URLs share a cache, including failures. Successful checks are
cached for six hours; errors retry after 30 minutes. The cache is persisted in
the bridge's Openplanet storage as `pack-updates-v1.json`, so reloading the bridge
does not normally start another request. Checks are serialized, time out after
five seconds, have a global two-second minimum between HTTP starts, and stop on
disable/unload. A maximum of 64 URL entries bounds
storage; inactive historical entries are evicted when current packs need room.
The bridge and in-flight checks are retained. Only the bridge and currently
enabled, registered packs are checked.

The last valid result survives transient errors and is marked stale. The worker
requests a bounded byte range and rejects partial, oversized, malformed, and
unsuccessful responses. Openplanet exposes download progress rather than a hard
transport buffer cap, so an uncooperative server may transiently buffer more
than the response limit before cancellation. Host this tiny file on a reliable
static server.

Users can turn checks off in **Openplanet Settings → TM Control MCP → Updates**.
That tab displays the same cached status as discovery. Checks do not download or
install plugins, and they work independently of whether the local control
socket is enabled.

## Read the result

```bash
python3 tools/call.py ListToolPacks
```

`output.packs[]` retains `id`, `plugin`, `toolCount`, and `enabled`, and adds:

| Field | Meaning |
| --- | --- |
| `installedVersion` | Actual installed Openplanet plugin version |
| `latestReleaseUrl` | Pack-declared canonical version-file URL |
| `latestVersion` | Last valid result, normalized without leading `v`; empty if unknown |
| `updateAvailable` | Boolean; true only for a known newer version while checks are enabled |
| `updateStatus` | State listed below; inspect this before treating false as current |
| `updateError` | URL warning or most recent request/validation error |
| `updateStale` | Last successful result is expired or followed by a failed check |
| `lastCheckedAt`, `lastSuccessAt`, `nextCheckAt` | Unix seconds; zero means not yet known |
| `warnings` | Missing/invalid metadata or cache-capacity warnings |

`output.bridge` uses the same fields for tm-control-mcp itself and its own
version URL. The bridge is not inserted into `packs`, so the existing pack count
and iteration behavior are preserved.

States: `missing_url`, `invalid_url`, `disabled`, `cache_full`, `pending`,
`checking`, `error`, `stale`, `installed_version_unknown`, `update_available`,
`up_to_date`. `up_to_date` means there is no newer advertised version, including
when a development install is ahead. A cached newer version can remain
`updateAvailable: true` during `checking` or `stale`; use the timestamps and
`updateStale` to judge freshness. False in an error/unknown/disabled state is
**not** evidence that an install is current.

## Preferred publishing: one GitHub Pages deployment

Serve the file alongside your full static site. Use one Pages workflow and one
artifact containing **both** the site and `latest-version.txt`. A second
version-only deployment would replace the site.

1. Copy [`templates/pack-pages.yml`](templates/pack-pages.yml) into your pack as
   `.github/workflows/pages.yml`. Change `master` to your default branch if needed.
2. Enable **Settings → Pages → Build and deployment → GitHub Actions**.
3. If you have a site generator, replace the template's site-build step with
   your build. Point its output at `_site/` (or update both following steps).
4. Keep the version-writing step **after** the site build and **before** the
   single `upload-pages-artifact` step. Generators often delete their output.
5. Add `SetLatestReleaseUrl` with your Pages project URL, including the repository
   path. Keep your installed manifest version synchronized with your release tag.
6. Publish/tag a stable release and verify the live file returns exactly that
   version, while the site still loads.

The template builds the site from the current default branch, regardless of
which release event triggered it. It takes the highest stable numeric tag
(`vX.Y.Z` or `X.Y.Z`) and validates the `info.toml` **at that tag**, never the
unreleased version on the default branch. Older release edits and out-of-order
events cannot advertise an older version. Pre-release tags are ignored. Tags
are a publication boundary: push a stable tag only when the release is ready.
To withdraw a version, remove its tag as well and manually dispatch Pages.

The template also runs on branch pushes, stable tag pushes, release publication/
edits/deletion, and manual dispatch. All runs share the `github-pages`
concurrency group. A repository with an existing Pages workflow should **merge
these steps into it**, removing any competing deploy workflow.

tm-control-mcp uses this approach:

- Site: <https://clankercode.github.io/tm-control-mcp/>
- Version: <https://clankercode.github.io/tm-control-mcp/latest-version.txt>
- Build: [`tools/build_site.py`](../tools/build_site.py)
- Deployment: [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)
- Local preview: `python3 tools/build_site.py`, then
  `python3 -m http.server 8000 --directory _site`

## Follow-ups for existing packs

These are follow-ups only; this change does not edit any pack repository. All
five currently use `master` and need the common Pages/template setup above,
their own stable release tag, and a rebuilt pack after updating the bridge.
Add the setter immediately after the builder at the path shown:

| Pack / repository | Registration | `SetLatestReleaseUrl` argument |
| --- | --- | --- |
| [Editor++](https://github.com/clankercode/tm-mcp-pack-epp) | `src/Main.as` (default plugin-ID prefix) | `https://clankercode.github.io/tm-mcp-pack-epp/latest-version.txt` |
| [Ghosts++](https://github.com/clankercode/tm-mcp-pack-gpp) | `src/Pack.as` (`GhostsPP`) | `https://clankercode.github.io/tm-mcp-pack-gpp/latest-version.txt` |
| [Visual](https://github.com/clankercode/tm-mcp-pack-visual) | `src/Pack.as` (`PACK_ID`) | `https://clankercode.github.io/tm-mcp-pack-visual/latest-version.txt` |
| [MLHook](https://github.com/clankercode/tm-mlhook-mcp-pack) | `src/Pack.as` (`MLHook`) | `https://clankercode.github.io/tm-mlhook-mcp-pack/latest-version.txt` |
| [Map Together](https://github.com/clankercode/tm-map-together-mcp-pack) | `src/Pack.as` (`MapTogether`) | `https://clankercode.github.io/tm-map-together-mcp-pack/latest-version.txt` |

For each pack, verify registration has no metadata warning, the installed
version matches its manifest, an equal version reports `up_to_date`, a newer
test version reports `update_available`, and a failed endpoint keeps the pack's
tools usable. Use a temporary endpoint for these checks; do not publish a fake
newer production version.
