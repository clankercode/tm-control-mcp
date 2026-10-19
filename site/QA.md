# QA — tm-control-mcp site

Not deployed (`*.md` and dotfiles are excluded by `tools/build_site.py`).
Screenshots are **not committed**. They are regenerated into `/tmp` with the commands below.
Every capture uses its own headless Playwright Chromium, launched and closed by the
script. No shared CDP browser (9233/9244) was used.

## Sources of truth

- `site/PRODUCT.md`, `site/DESIGN.md` (mode: Banger, controlled; thesis: editor HUD × race timing screen)
- Facts: `README.md`, `CHANGELOG.md`, `SECURITY.md`, `info.toml`, `src/Protocol.as`
  (envelope `ok,id,route,error,data`), `src/McpTools.as` (schemas, error codes),
  `src/EditorOptional.as` (E++ tools moved to pack), `docs/tool-packs.md`,
  `docs/pack-updates.md`, `tools/call.py`, GitHub descriptions of the five packs.
- Image: `docs/images/editor-demo.jpg` (committed in `830983d`), re-encoded to 1600w WebP/JPEG.

## Reproduce

Playwright resolution: `$PLAYWRIGHT_MODULE` (path to a `playwright` package), or
`playwright` installed in the working directory (`npm i --no-save playwright && npx playwright install chromium`).

```sh
python3 tools/build_site.py --output /tmp/tmcm-site          # site + latest-version.txt
python3 -m http.server 33956 --bind 127.0.0.1 --directory /tmp/tmcm-site
node site/.qa/render.mjs http://127.0.0.1:33956/ /tmp/tmcm-final shots          # 7 viewport/theme captures + report.json
node site/.qa/states.mjs http://127.0.0.1:33956/ /tmp/tmcm-final/states         # focus, copy, CP3, nav, no-JS
python3 site/.qa/slice.py /tmp/tmcm-final/desktop-1440-night-full.png /tmp/tmcm-final/dn 1100
# Assets (committed outputs):
node site/.qa/render.mjs site/og-source.html site/assets og                     # assets/og-image.png 1200x630
node site/.qa/render.mjs - site/assets icons                                     # favicon-32.png, apple-touch-icon.png
python3 site/.qa/imgdiff.py /tmp/x/og-image.png site/assets/og-image.png         # pixel diff (None = identical)
```

Fonts are subsets of system OFL fonts (`pyftsubset`, `fonttools varLib.instancer`):
Inter Variable upright wght 400–800, Inter Italic wght 700–900 opsz 32,
JetBrains Mono 400/700, Latin plus punctuation and arrows. Licences are in `assets/fonts/`.

## Capture matrix (final, commit 27f214b)

| Capture | Viewport | Mood | Result |
|---|---:|---|---|
| desktop-1440-night top/full | 1440×1000 | Night | PASS. No page errors, scrollWidth = viewport, version chip `v0.4.0`, live file `0.4.0` |
| desktop-1440-day top/full | 1440×1000 | Day | PASS |
| tablet-1024-night | 1024×768 | Night | PASS (hero stacks; trace below) |
| mobile-390 night/day | 390×844 | both | PASS (scrolling nav; packs stacked; socket rows) |
| narrow-320 night/day | 320×640 | both | PASS (icon-only header tools; trace gates fit; copy icon-only in trace) |
| trace CP3 + keyboard focus | 1440 / 390 / 320 | — | PASS: ArrowRight×3 → `gate-3` selected+focused, `CP 3 / 5`, one panel visible, marker ends at CP3 |
| copy button | 1440 / 390 / 320 | — | PASS: clipboard reads the exact `call.py` command; button shows "Copied"; polite live-region announcement |
| CTA focus | 1440 / 390 / 320 | — | PASS: inset dark/yellow ring visible inside the clipped shape |
| nav "Updates" focus | 390 / 320 | — | PASS: link scrolled fully into view (390: 310–390, 320: 228–308); ring inside |
| no-JS | 390 | Night | PASS: all 7 steps visible; Prev/Next and Mood button absent (`[hidden]` enforced) |
| OG card | 1200×630 + 300w thumb | — | PASS: two-line title, one-line subline, progress ends at CP3 centre (geometry noted in source); parent independent geometry + vision PASS at `4fbee27` |

Vision review was done by viewing the actual PNGs, with banded slices and crop-zooms.

## Delta ledger (all observed closed after recapture)

| ID | Sev | Finding | Fix |
|---|---|---|---|
| V-001 | P1 | Hero socket `127.0.0.1:30006` wrapped mid-address | `nowrap` on the address; columns `auto` (a first `nowrap` on all `dd`s caused an overlap, caught and reverted) |
| V-002 | P2 | Version chip read "Latest releasev0.4.0" (whitespace collapses in a flex chip) | `gap` on chip + wrapped text span |
| V-003 | P1 | Install folder numbers invisible in Night (`.folder p` colour overrode the tab) | Selector scoped to `:not(.folder__tab)` |
| V-004 | P2 | Route JSON broke mid-word ("inpu t") | `<wbr>` after JSON commas in the tint pass |
| V-005 | P2 | Copy button covered the `git clone` line | Every copyable block has a label row hosting the button |
| V-006 | P2 | Replies scrolled out of sight | Reply blocks wrap |
| V-007 | P2 | Packs table needed horizontal scroll under 720px | Rows stack (name + id, then description) |
| V-008 | P2 | AngelScript label wrapped one letter under the copy button | Labels are single-line, with an ellipsis; text shortened |
| V-009 | P2 | 320px trace command broke mid-word next to a 92px copy button | Icon-only copy (accessible name kept) + comma break points |
| V-010 | P2 (review) | CTA `clip-path` clipped the focus outline | Inset focus ring + underline |
| V-011 | P2 (review) | No-JS showed inert Prev/Next and Mood | Global `[hidden]{display:none!important}` |
| V-012 | P2 (review) | Permanent nav fade hid "Updates" when scrolled; 390px focus left link clipped | Mask removed, trailing padding, `focusin` → `scrollIntoView` |
| V-013 | P2 (review) | `.op` route used `tools/call.py` without the repo or Python | Step 4 "Get the client" (Python 3, clone); 5 steps |
| V-014 | P2 (review) | CP1 used raw `decoration:"48x48Day"` | `{"environment":"Stadium"}` (default vista) |
| V-015 | P2 (review) | Failed-tool example showed only the inner result | Full envelope with `data.result.success:false`; replies use real `ok,id,route,error,data` |
| V-016 | P2 | OG title wrapped to 3 lines into the track; progress overshot CP3 | Two-line title, one-line subline, car width from gate centres |

## Final statement

- P0: 0. P1: 0.
- Accepted P3: long code (AngelScript URL, Python client) scrolls horizontally inside
  keyboard-focusable blocks instead of wrapping (wrapping would corrupt copy/paste
  readability). The trace still elides reply payloads with `…` by design.
- Both moods complete; preference follows the system, toggle persists (`localStorage` `tmcm-mood`), no flash.
- Reduced motion: transitions and smooth scroll off; captures run with `reducedMotion: reduce`.
- Known limits: `latest-version.txt` only exists in the built artifact, so local `file://`
  or a raw `site/` preview shows "unavailable/served with the deployed site". The README
  still documents stale `wrong_mode`/E++-builtin details (parent owns README).
  `hideOverlay` is described as "overlay rendering switched off" because the code sets
  `Viewport.DisableOverlayRender`.
