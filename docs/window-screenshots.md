# Capturing Openplanet and plugin windows

`TakeScreenshot` queues Trackmania's native viewport capture. It does not capture
Openplanet's ImGui menu, settings, or plugin windows. `hideOverlay:false` does not
add them: that option controls the game's own HUD/Manialink overlay rendering.
Use a desktop compositor capture when reviewing plugin UI.

On **xsm, KDE Plasma 6.7.5 / Wayland with Trackmania under Proton**, this works:

```bash
# Make the intended Openplanet/plugin window visible first, then activate TM.
xdotool search --name '^Trackmania$' windowactivate --sync
spectacle -b -n -a -o /tmp/trackmania-with-openplanet.png
```

Inspect the saved image and confirm the intended plugin title/content is visible.
`-a` captures the active window; verify focus, especially when multiple matching
windows exist. This was checked on 2026-10-20: the captured Trackmania window
contained both Openplanet settings and the Dips++ CustomMap Editor window.

For a desktop capture, use `spectacle -b -n -f -o /tmp/desktop.png` and crop the
Trackmania area before sharing. Desktop captures can include unrelated windows.
Run in the logged-in graphical session, with its `DISPLAY`, Wayland and D-Bus
environment. A shell sandbox may block compositor access; use the authorized
outside-sandbox game-command path. A running game/process list or a created file
alone does not prove that the desired UI appears in the image.

`ControlOverlay {"action":"show"}` shows Openplanet's overlay; opening a particular
plugin window is separate. `ControlPlugin {"action":"openSettings","id":"tm-control-mcp"}`
opens its settings. Preserve the prior overlay/window state after capture.
