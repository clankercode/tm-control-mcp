#!/usr/bin/env python3
"""Retain and restore running registered tool-pack consumers for build.sh.

All calls are sequential. Unknown state never authorizes a load; any failed
restore stops the sequence and returns nonzero to the build caller.
"""
import json
from pathlib import Path
import subprocess
import sys


class UnknownState(ValueError):
    pass


def tool_output(response):
    if not isinstance(response, dict) or response.get("ok") is not True:
        raise UnknownState("transport response unsuccessful or malformed")
    data = response.get("data")
    result = data.get("result") if isinstance(data, dict) else None
    if not isinstance(result, dict) or result.get("success") is not True:
        raise UnknownState("tool result unsuccessful or malformed")
    output = result.get("output")
    if not isinstance(output, dict):
        raise UnknownState("tool output is not an object")
    return output


def call_tool(tool, arguments):
    try:
        process = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("call.py")),
             tool, json.dumps(arguments)],
            capture_output=True, text=True, timeout=25,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UnknownState(f"{tool} unavailable ({type(exc).__name__})") from exc
    if process.returncode != 0:
        raise UnknownState(f"{tool} client exited {process.returncode}")
    try:
        return tool_output(json.loads(process.stdout))
    except (ValueError, TypeError) as exc:
        raise UnknownState(f"{tool}: invalid or unsuccessful response") from exc


def typed_entries(output, key, id_key):
    entries = output.get(key)
    if not isinstance(entries, list):
        raise UnknownState(f"{key} is not an array")
    for entry in entries:
        if (not isinstance(entry, dict)
                or not isinstance(entry.get(id_key), str) or not entry[id_key]
                or type(entry.get("enabled")) is not bool):
            raise UnknownState(f"{key} contains a malformed entry")
    return entries


def loaded_plugins():
    # Include disabled entries so they cannot be mistaken for unloaded plugins.
    entries = typed_entries(call_tool("ListPlugins", {"includeDisabled": True}),
                            "plugins", "id")
    plugins = {entry["id"]: entry["enabled"] for entry in entries}
    if len(plugins) != len(entries):
        raise UnknownState("plugins contains duplicate IDs")
    return plugins


def snapshot(provider):
    packs = typed_entries(call_tool("ListToolPacks", {}), "packs", "plugin")
    plugins = loaded_plugins()
    return list(dict.fromkeys(
        pack["plugin"] for pack in packs
        if pack["plugin"] != provider and pack["enabled"]
        and plugins.get(pack["plugin"]) is True
    ))


def restore(previous):
    if (not isinstance(previous, list)
            or any(not isinstance(plugin, str) or not plugin for plugin in previous)):
        raise UnknownState("retained plugin set is malformed")
    for plugin in dict.fromkeys(previous):
        # Recheck before every load: an earlier load may have loaded a peer too.
        plugins = loaded_plugins()
        if plugin in plugins:
            if plugins[plugin]:
                print(f"Tool-pack plugin {plugin} is already running; skipping load")
                continue
            raise UnknownState(f"{plugin} is now disabled; skipping load")
        print(f"Loading previously running tool-pack plugin {plugin}")
        call_tool("ControlPlugin", {"action": "load", "id": plugin})
        if loaded_plugins().get(plugin) is not True:
            raise UnknownState(f"{plugin} is not confirmed running after load")
        print(f"Tool-pack plugin {plugin} confirmed running after load")


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2 or args[0] not in {"snapshot", "restore"}:
        print("usage: build_pack_state.py snapshot PROVIDER | restore JSON_IDS", file=sys.stderr)
        return 2
    try:
        if args[0] == "snapshot":
            print(json.dumps(snapshot(args[1])))
        else:
            restore(json.loads(args[1]))
    except (ValueError, TypeError) as exc:
        print(f"warning: tool-pack {args[0]} incomplete: {exc}; "
              "remaining restoration skipped safely", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
