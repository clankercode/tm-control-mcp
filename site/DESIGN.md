# DESIGN — tm-control-mcp project site

Not deployed (`*.md` is excluded by `tools/build_site.py`).

## Mode

**Banger (controlled)**, with Docs-grade reading sections. It is a project/launch
page for a developer tool, so it needs a memorable identity, but every section
below the hero is reference material that must read like good docs: real commands,
copyable, high contrast, no decoration standing in for content.

## Visual thesis

For Openplanet plugin authors and agent builders wiring scripts into Trackmania,
the site feels like **the map editor's own HUD seen through a race timing screen**:
editor-green chrome bars, signal-yellow slanted tabs, near-black viewport canvas and
monospace wire traffic, with an example session laid out as **checkpoints from START
to FINISH** — so the bridge reads as a native part of the game's toolchain, not a SaaS.

## Character

- **Native** — colours and slanted HUD geometry come from the Trackmania editor
  (green toolbar, yellow MODES/folder tabs; see `docs/images/editor-demo.jpg`).
- **Precise** — monospace for anything on the wire; exact tool names, real schemas.
- **Fast** — italic heavy display type, angled edges, a sliding checkpoint marker.
- **Honest** — no counters, fake activity, or invented responses; elided output is shown as `…`.

## References → adopted properties

- Trackmania map editor HUD (repo screenshot): green bottom toolbar, yellow
  parallelogram buttons with heavy italic caps, numbered yellow folder tabs, panels
  with one angled edge, dark viewport.
- Trackmania race HUD: checkpoint counter (`CP 2 / 5`), split colours —
  **blue = ahead/ok**, **red = behind/error** — reused as semantic success/danger.
- Openplanet overlay: dense dark panels, monospace data.

## Anti-references

- Generic SaaS hero with gradient blob + floating cards → replaced by the
  checkpoint trace (a real protocol walkthrough) as the focal object.
- Equal-weight rounded feature cards → ruled "sector" columns (S1/S2/S3) on one surface.
- Purple/indigo AI gradient → editor green + signal yellow only.
- Fake terminal with invented output → only documented request/envelope shapes.

## Prototype comparison (structural, paper/HTML sketch)

| Variant | Structure | Verdict |
|---|---|---|
| A. Checkpoint trace hero | Claim + install CTA left, interactive START→FINISH session right; sectors below | **Winner** — teaches the protocol in the first screen; subject-native metaphor |
| B. Docs-first | Sidebar nav + long reference page, small header | Loses identity; duplicates README; weak first-screen answer |
| C. Screenshot-led | Full-bleed editor capture hero with overlaid copy | The only real capture is mostly black; claims nothing about the socket |

Stolen from losers: B's copyable code blocks and anchor nav; C's real screenshot as a
framed proof figure below the fold.

## Information hierarchy

1. What it is + primary action (Download `.op` / GitHub) + socket address.
2. Checkpoint trace (how a client actually talks to it).
3. What it controls (Editor / Menu / Race & play, agent ergonomics, Openplanet).
4. Proof capture, protocol details, install steps.
5. Tool packs, update/version convention, safety, footer.

```
[ green header: mark · nav · Mood ]
[ hero: kicker · H1 · lede · CTAs · socket ][ CHECKPOINT TRACE panel ]
[ 01 Controls: S1 Editor | S2 Menu | S3 Race ][ agents row ][ Openplanet row ]
[ framed real capture ]
[ 02 Protocol: routes + envelope | python stdlib client ]
[ 03 Install: folder tabs 1-4 with copy ]
[ 04 Packs: ruled table ]
[ 05 Updates: version convention | live latest-version.txt ]
[ safety strip ][ footer ]
```

## Signature move

**Checkpoint trace**: an example agent session (`status` → `EditNewMap` →
`WaitUntil` → `PlaceBlock` → `TakeScreenshot` → `SaveMapAs` → `BackToMainMenu`)
drawn as START, CP1–CP5, FINISH gates. Each gate is a tab showing the `call.py`
command (copyable), the exact JSON line on the wire, the reply envelope, and why
the step exists. A yellow marker slides between gates. Keyboard: arrow keys, Home,
End. Reduced motion: marker jumps. No JS: every step renders as an ordered list.

## Layout and density

Max content width 1200px, 24px gutters (16px under 400px). Hero 2 columns from
1080px. Sections separated by rules, not cards. Code blocks scroll horizontally
(keyboard-focusable); trace JSON wraps.

## Typography

- Display: Inter Variable **Italic**, 700–900, opsz 32 (self-hosted subset). Mixed case
  for H1/H2; caps only on small tabs.
- Body/UI: Inter Variable upright 400–800 (self-hosted subset), 17px/1.6, measure ≤ 68ch.
- Code/data: JetBrains Mono 400/700 (self-hosted subset).
- Fonts: OFL, licences shipped in `assets/fonts/`. No network fonts.

## Semantic colour and themes ("Mood")

Two first-class themes named after Trackmania moods: **Night** (dark) and **Day**
(light). Default follows `prefers-color-scheme`; the header toggle persists to
`localStorage`; a head script prevents flash.

| Token | Night | Day |
|---|---|---|
| canvas | `#0d1110` | `#eceee8` |
| surface / surface-2 | `#141a18` / `#1b2420` | `#f8f9f5` / `#e1e5de` |
| text / text-2 / muted | `#eef2ef` / `#bac5c0` / `#93a09a` | `#0e1512` / `#33403a` / `#56635d` |
| chrome (editor green) | `#0b6e43` | `#0a6a40` |
| signal (yellow fill) | `#f4c21b` | `#f4c21b` |
| link | `#f4c21b` | `#0a6a40` |
| ahead (ok) / behind (error) | `#5aa5ff` / `#ff6b6b` | `#1f5fd1` / `#c4252b` |

Code panels stay dark in both moods (they represent the wire / a terminal); their
tokens are tuned once against the dark code background.

## Geometry and material

Radius 0–6px. HUD panels and buttons use one **angled edge** (14px) via
`clip-path`. Elevation by colour steps and 1px rules, no glass, one soft shadow on
the trace panel. Faint 32px editor grid only behind the hero.

## Imagery and iconography

Only real imagery: `docs/images/editor-demo.jpg` (TakeScreenshot capture committed
2026-08-12 in `830983d`), re-encoded to WebP/JPEG 1600w. Icons are inline SVG,
stroke 2px, no icon tiles.

## Motion

Utility only: marker slide 260ms ease-out, button press 120ms, copy confirmation.
`prefers-reduced-motion: reduce` disables transitions and smooth scroll.

## Accessibility

Landmarks (`header`, `nav`, `main`, `footer`), skip link, one H1, ordered H2/H3.
Visible 3px focus ring (yellow on dark, green on light). Trace uses the ARIA tabs
pattern. Copy buttons announce via a polite live region. Contrast ≥ 4.5:1 for text.
Targets ≥ 40px on touch layouts.

## Settled decisions

- No tool counts, stars, download numbers, or testimonials.
- Version shown only from `./latest-version.txt`; fallback copy says "latest release".
- Design source `og-source.html` is excluded from deploy by name; QA evidence lives in
  `site/.qa/` (dotfiles are excluded by the build's `.*` ignore).
