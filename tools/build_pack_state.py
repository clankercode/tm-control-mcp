#!/usr/bin/env python3
"""Retain and restore previously registered, enabled consumers for build.sh.

All calls are sequential. Unknown state never authorizes a load; any failed
restore stops the sequence and returns nonzero to the build caller.
Registry confirmation establishes registration, not whole-plugin runtime health.
"""
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import subprocess
import sys
import time


REGISTRATION_TIMEOUT = 5.0
POLL_INTERVAL = 0.1
IDENTITY_KEYS = ("id", "source", "type", "sourcePathBase", "sourcePath")


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


def call_tool(tool, arguments, *, timeout=25):
    try:
        process = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("call.py")),
             tool, json.dumps(arguments), "--timeout", str(min(timeout, 5.0))],
            capture_output=True, text=True, timeout=timeout,
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


def loaded_plugins(*, timeout=25):
    # Include disabled entries so they cannot be mistaken for unloaded plugins.
    entries = typed_entries(call_tool("ListPlugins", {
        "includeDisabled": True, "includeSourcePath": True,
    }, timeout=timeout),
                            "plugins", "id")
    plugins = {entry["id"]: entry for entry in entries}
    if len(plugins) != len(entries):
        raise UnknownState("plugins contains duplicate IDs")
    return plugins


def identity(entry):
    """Validate a runtime descriptor; never guess a path from an ID.

    Paths are retained only in the transient snapshot passed by build.sh. They
    may be Windows/Wine or POSIX paths, independent of this helper's host OS.
    """
    if (not isinstance(entry, dict)
            or any(not isinstance(entry.get(key), str) or not entry[key]
                   or any(ord(ch) < 32 for ch in entry[key])
                   for key in IDENTITY_KEYS)):
        raise UnknownState("plugin descriptor contains a malformed identity")
    if (entry["source"] not in {"ApplicationFolder", "UserFolder"}
            or entry["type"] not in {"Folder", "Zip"}):
        raise UnknownState("unsupported plugin source or type")
    plugin_id = entry["id"]
    if (plugin_id != plugin_id.strip() or ".." in plugin_id
            or any(ch in plugin_id for ch in "/\\:") or not plugin_id.strip(". ")):
        raise UnknownState("plugin ID is not a safe lifecycle identifier")
    path = entry["sourcePath"].replace("\\", "/").rstrip("/")
    if (not (PurePosixPath(path).is_absolute() or PureWindowsPath(path).is_absolute())
            or ".." in PurePosixPath(path).parts
            or path.rsplit("/", 1)[-1] != entry["sourcePathBase"]
            or entry["sourcePathBase"] in {".", ".."}):
        raise UnknownState("plugin source path is ambiguous or inconsistent")
    if entry["type"] == "Zip" and not path.lower().endswith((".op", ".zip")):
        raise UnknownState("unsupported archive path")
    return {key: entry[key] for key in IDENTITY_KEYS}


def registered_packs(*, timeout=25):
    entries = typed_entries(call_tool("ListToolPacks", {}, timeout=timeout),
                            "packs", "plugin")
    packs = {}
    for entry in entries:
        pack_id = entry.get("id")
        if (not isinstance(pack_id, str) or not pack_id or "." in pack_id
                or any(ord(ch) < 32 for ch in pack_id) or pack_id in packs):
            raise UnknownState("packs contains a malformed or duplicate ID")
        packs[pack_id] = entry
    return packs


def snapshot(provider):
    packs = registered_packs()
    plugins = loaded_plugins()
    retained = {}
    for pack in packs.values():
        plugin_id = pack["plugin"]
        current = plugins.get(plugin_id)
        if (plugin_id == provider or not pack["enabled"]
                or current is None or not current["enabled"]):
            continue
        if plugin_id not in retained:
            retained[plugin_id] = {**identity(current), "packs": []}
        retained[plugin_id]["packs"].append(pack["id"])
    return list(retained.values())


def validate_previous(previous):
    if not isinstance(previous, list):
        raise UnknownState("retained consumer set is malformed")
    plugin_ids, pack_ids = set(), set()
    for entry in previous:
        descriptor = identity(entry)
        packs = entry.get("packs")
        if (descriptor["id"] in plugin_ids or not isinstance(packs, list) or not packs
                or any(not isinstance(pack, str) or not pack or "." in pack
                       or any(ord(ch) < 32 for ch in pack) for pack in packs)
                or len(set(packs)) != len(packs) or pack_ids.intersection(packs)):
            raise UnknownState("retained consumer or pack identities are malformed/duplicated")
        plugin_ids.add(descriptor["id"])
        pack_ids.update(packs)


def check_current(previous, current):
    if current is not None:
        if identity(current) != identity(previous):
            raise UnknownState(f"{previous['id']} identity changed; retained descriptor preserved")
        if not current["enabled"]:
            raise UnknownState(f"{previous['id']} is now disabled; skipping load")


def check_compile(output):
    report = output.get("compile")
    if not isinstance(report, dict):
        raise UnknownState("load compilation report missing or malformed")
    # A missing/false 'loaded' log marker alone proves neither success nor
    # failure. The registry is checked below; explicit negative diagnostics win.
    for key in ("loaded", "compileFailed"):
        if key in report and type(report[key]) is not bool:
            raise UnknownState("load compilation report has malformed flags")
    errors = report.get("errorCount", 0)
    if type(errors) is not int or errors < 0:
        raise UnknownState("load compilation report has malformed error count")
    if report.get("compileFailed") is True or errors > 0:
        raise UnknownState("load compilation failed or reported errors")


def wait_registered(previous):
    deadline = time.monotonic() + REGISTRATION_TIMEOUT

    def remaining():
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise UnknownState(f"{previous['id']} pack registration not confirmed before deadline")
        return seconds

    while True:
        current = loaded_plugins(timeout=remaining()).get(previous["id"])
        check_current(previous, current)
        packs = registered_packs(timeout=remaining())
        for pack_id in previous["packs"]:
            if pack_id in packs and packs[pack_id]["plugin"] != previous["id"]:
                raise UnknownState(f"{pack_id} is registered by a different plugin")
        if (current is not None and all(
                pack_id in packs and packs[pack_id]["enabled"]
                for pack_id in previous["packs"])):
            remaining()
            return
        time.sleep(min(POLL_INTERVAL, remaining()))


def restore(previous):
    # Validate the entire snapshot before any game contact or mutation.
    validate_previous(previous)
    for descriptor in previous:
        plugin_id = descriptor["id"]
        # Recheck before every load: an earlier load may have loaded a peer too.
        plugins = loaded_plugins()
        current = plugins.get(plugin_id)
        check_current(descriptor, current)
        if current is None:
            print(f"Loading previously registered tool-pack plugin {plugin_id}")
            path = descriptor["sourcePath"]
            # ControlPlugin also infers Zip from a path extension; a folder's
            # trailing slash keeps even a folder named *.op unambiguous.
            if descriptor["type"] == "Folder":
                path = path.rstrip("/\\") + "/"
            output = call_tool("ControlPlugin", {
                "action": "load", "id": plugin_id, "path": path,
                "source": descriptor["source"], "type": descriptor["type"],
            })
            check_compile(output)
        # Enabled placeholders remain unknown until all prior packs reappear.
        # Never reload/enable an existing entry to try to repair that state.
        wait_registered(descriptor)
        print(f"Tool-pack plugin {plugin_id}: prior packs confirmed registered")


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2 or args[0] not in {"snapshot", "restore"}:
        print("usage: build_pack_state.py snapshot PROVIDER | restore JSON_DESCRIPTORS", file=sys.stderr)
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
