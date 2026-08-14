# Issue tracker: GitHub

Issues for this repo live as GitHub issues (`clankercode/tm-control-mcp`). Use the `gh` CLI.

## Conventions

- **Create**: `gh issue create --title "..." --body "..."`
- **Read**: `gh issue view <number> --comments`
- **List**: `gh issue list --state open`
- **Comment**: `gh issue comment <number> --body "..."`
- **Labels**: `gh issue edit <number> --add-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`. `gh issue create --label wayfinder:map`.
- **Child ticket**: GitHub sub-issue when enabled; otherwise add the child to a task list in the map body and put `Part of #<map>` at the top of the child. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: GitHub native issue dependencies when available; else `Blocked by: #<n>` at the top of the child body.
- **Claim**: `gh issue edit <n> --add-assignee @me`
- **Resolve**: comment the answer, close, append a gist+link to the map's Decisions-so-far.
