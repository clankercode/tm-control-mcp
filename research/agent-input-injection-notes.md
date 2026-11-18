# Agent input injection into TM instances — findings (2026-11-18)

Context: driving the Garage skin browser needed real menu input (see
`../spike.fix-skin-browser-charpilot/AGENTS.md` for the full story). Facts observed on
x-boss (KDE Wayland + XWayland, Proton TM2020, instance windows on the `Agent` desktop):

## What does NOT work

1. **tm-control-mcp `TriggerControlOnAction` / `ClickMenuButton`** — fires
   `CControlBase::OnAction`, which reaches nav-zone component buttons (route pushes,
   e.g. HomePage → Create → Garage) but NOT page Select() handlers driven by the
   Navigation component's own event queue (garage tabs, `button-edit`, `button-upload`).
   Returns success even when the page ignores it — misleading.
2. **xdotool (XTEST) synthetic keys/clicks to the focused XWayland TM window** — the
   window verifies as active (`xdotool getactivewindow` == game window), keys sent with
   both default (12ms) and held (150ms) press durations, clicks at window-relative coords:
   the menu does not react (no tab switch on Page_Down, no focus move on arrows, no
   chevron click). Physical keyboard PageUp/PageDown DOES switch tabs (confirmed by Max
   at the physical keyboard). Likely cause: TM reads keyboard/mouse through a raw-input
   path that filters XTEST-injected events (XTEST core events do not produce XInput2
   *raw* events; games on raw input never see them). The in-game key-hints bar appearing
   was later attributed to the USER's typing while the window had focus, not to
   synthetic keys.
3. Click coordinate mapping is additionally ambiguous: window 1949x1080 vs engine
   screenshot 1920x1080 (pillarbox/offset unknown) — moot while clicks don't land at all.

## What WORKS (proven in game, tm7, 2026-11-18): in-process nav event injection

No OS input needed. The menu ManiaApp turns every nav key into a layer custom event
(`MenuLibs/Common/Menu/ShareMenuNavigation.Script.txt:45-48`, parsed at :100-118).
Sending the same event from AngelScript drives Navigation-component pages (garage, skin
browser) exactly like a key press, whatever window has OS focus:

    auto owner = cast<CTrackMania>(GetApp()).MenuManager.MenuCustom_CurrentManiaApp;
    MwFastBuffer<wstring> d;
    d.Add(wstring("::EMenuNavAction::Down"));   // Up|Down|Left|Right|Select|Cancel|...
    d.Add(wstring("false")); d.Add(wstring("0")); d.Add(wstring("false"));  // autoRepeat, userIndex, fromMouse
    for (uint i = 0; i < owner.UILayers.Length; i++)
        owner.LayerCustomEvent(owner.UILayers[i], wstring("ShareMenuNavigation_MenuNavigation"), d);

Implemented in `spike.fix-skin-browser-charpilot/src/DevNav.as`, which also refuses a
Select unless a focused control (`IsFocused`) id/label matches an expected string. **That
guard matters:** an unguarded injected Select that landed on the home page closed the
game. This is the best basis for the `SendMenuInput` tool below; it makes the virtual
gamepad/uinput ideas unnecessary for menu navigation.

## What could work (candidate implementations, untested)

- **uinput (kernel-level virtual keyboard/mouse)**: events enter the evdev layer and are
  indistinguishable from hardware; Wine/Proton raw input sees them. Needs the instance
  window to have keyboard focus (focus discipline via tmc window identity), and affects
  whatever has focus system-wide — must coordinate with the user/lease system. This is
  the only software path likely to reach TM's raw input.
- **vJoy/SDL virtual gamepad (hidrd or sdl2-virtual)**: SDL virtual device per session;
  TM menu nav accepts gamepad (dpad = arrows, A = select, LB/RB = tabs). A per-instance
  SDL device could be scoped via `SDL_GAMECONTROLLER_IGNORE_DEVICES` on the other
  instances (they already set big ignore lists). Probably the cleanest multi-instance
  story: menu nav only needs dpad/A/LB/RB.

## Suggested tm-control-mcp tooling (for an agent to implement)

- `SendMenuInput {key: dpad_up|dpad_down|dpad_left|dpad_right|select|cancel|tab_next|tab_prev}`:
  injects via virtual gamepad (preferred) or uinput, targeted at "the window of the
  instance this MCP serves" (window identity via tmc pids → `_NET_WM_PID`), with
  hold-for-N-ms press semantics (physical-like timing).
- `GetMenuFocusState` or extend `FindMenuButtons` with a `focused` flag
  (`CGameManialinkControl.IsFocused` is exposed) so agents can see where menu focus sits
  before sending input.
- Make `TriggerControlOnAction`/`ClickMenuButton` report when the target's page uses
  Navigation-component Select (i.e. OnAction will likely be ignored) instead of
  returning unconditional success.
- Document the "input ladder" for instances: MCP tools (read + OnAction) → virtual
  gamepad/uinput (real menu input) → human-in-the-loop, with the session-ceiling and
  focus-coordination caveats.
