# Terminal monitor visual review

User request: “we need to do a $visual-review-and-fix in detail over the TUI and compare it to your html mockups. Let's get the TUI way more in line with those mockups. Something to truly be proud of”.

Baseline: `24d7e66`. Reference mockups and real baseline terminal captures are hosted under `~/served-html/tm-control-mcp-tui/`. The original images must remain available. All Cargo builds and tests run on `x-p35`.

## Baseline evidence

| Surface | HTML reference | Actual baseline | Required change |
| --- | --- | --- | --- |
| Masthead | Separate application chrome, telemetry label, LIVE/PAUSED state, key hints | One cyan border with a single heading | Give brand, session state and controls distinct visual levels |
| Call history | Padded rows, distinct status and duration columns | Dense unstyled lines | Align adaptive columns and introduce breathing room |
| Selection | Cyan edge and blue background; red edge and tinted error selection | Selection has no visible styling | Make selected row immediately identifiable |
| Pack names | A second line preserves the tool suffix | Name truncated at 24 characters | Wrap long names using terminal cell widths |
| Details | Metadata spacing; separate outlined argument and result cards | One continuous monochrome text dump | Separate sections, style JSON tokens and tint failures |
| State | Filter, pause and follow modes visible | Filter disappears outside editing; footer says connecting after traffic | Persist mode indicators and report only observable facts |
| Scrolling | Scrollbar stays in its lane, selected call remains recognizable | Bright scrollbar dominates divider | Use a quiet scrollbar and preserve selection by invocation id |

## Design decision (IGC)

Context: the product is an installable native terminal monitor, already implemented with Ratatui; the approved HTML images express the desired visual language. Goals: G1 runs as a real terminal app; G2 reproduces the references' hierarchy, color and spacing; G3 remains usable in smaller terminals and ASCII mode.

| Idea | All | G1 | G2 | G3 |
| --- | :---: | :---: | :---: | :---: |
| Theme and improve the existing Ratatui renderer with responsive layouts | ✔ | ✔ | ✔ | ✔ |
| Show the HTML mockup as the monitor | ✘ | ✘ | ✔ | ✘ |
| Keep the renderer and only change terminal font/theme | ✘ | ✔ | ✘ | ✔ |

The HTML viewer fails the native terminal requirement. Terminal configuration alone cannot add selection styling, payload cards, adaptive columns or honest state indicators. The chosen renderer still needs empirical validation against the acceptance criteria below; the matrix is a design decision, not a validation receipt.

## Acceptance criteria

1. Match the references' navy panels, cyan identity, green success, amber active/paused and rose failures with a shared theme. Hierarchy comes from spacing, contrast and weight within terminal constraints.
2. Display application identity, the actual HTTP listen address, a prominent LIVE/PAUSED state, and context-sensitive key hints. Never invent native connectivity or hardcode an endpoint.
3. Use padded history rows, aligned status/duration columns, cell-aware long tool wrapping, a visible selected background and accent, and a subdued scrollbar. Selection and details must identify the same invocation.
4. Present metadata and distinct argument/result cards with readable JSON syntax coloring. Error results receive a restrained tinted background and border. Preserve the native error envelope and sanitized payloads.
5. Show the active filter, matching/hidden counts, pause state, follow/history state, and bounded-store statistics. Freeze elapsed time while paused. Preserve selection when the bounded history evicts older events, and reset detail scrolling when the selection changes.
6. Validate wide (164×46), standard (120×36), small (80×24), and very small terminals. Provide a useful narrow layout, bounded wrapped detail scrolling and ASCII fallbacks. Resizing must not panic or corrupt the display.
7. Exercise real keyboard interactions and MCP HTTP traffic in the screenshot harness, including active, error, paused/filter, scrollback, empty/filter-no-match and narrow states. Fixture traffic is disclosed; screenshots are direct terminal pixels, never HTML recreations.
8. Alternate vision review and independent geometry/source review. Capture and inspect changed regions at full resolution. Stop when both reviews pass the same revision, and record builds/tests and remaining limits honestly.

## Process guidance used

`~/Documents/workflows/README.md`, `01-the-loop.md`, `05-verify-and-evaluate.md`, and `07-pitfalls.md`: pin the baseline; define the contract before delegating; keep file ownership disjoint; use an independent reviewer who tries to break the change; verify seams; capture and inspect actual output; keep findings and receipts on disk. Tests do not substitute for visual comparison.

## Iterations and validation

### Baseline review

Independent vision and source reviewers agreed on the presentation gaps above and verified the following behavior defects from the baseline source:

- Detail scrolling counts logical lines rather than wrapped rows, making long payload tails unreachable.
- Selection is an index rather than an invocation identity; eviction or changing filter membership can silently change which call is inspected or exported.
- Pause freezes objects but not the rendering clock, so active elapsed time continues advancing.
- Error classification omits dispatcher statuses such as `invalid_arguments`, `unknown_tool`, `catalog_unavailable` and `queue_full`.
- Filter cancellation does not restore the previous filter, and follow mode can fight selection during editing.
- ASCII mode only changes status icons; chrome and truncation remain Unicode.
- Display truncation is silent, and temporary notices never expire.

These are verified against the code and baseline screenshots, not inferred from the mockup. The mockup's `native_error` label and “following newest” while inspecting a middle row are illustrative mistakes and are not copied into the implementation.

Baseline build-box check: `cargo test --all-targets --locked --jobs 2` on `x-p35` passed **22 library + 5 binary tests (27 total)**. No local Cargo commands were used. Actual screenshot capture tools and a private task font configuration are available on the build box so the next comparisons use the same JetBrains Mono font as the baseline.
