#!/usr/bin/env python3
"""Capture ManiaScript failure evidence without dismissing or restarting scripts."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def screenshot_error(response):
    envelope = response if isinstance(response, dict) else {}
    data = envelope.get("data")
    result = data.get("result") if isinstance(data, dict) else None
    output = result.get("output") if isinstance(result, dict) else None
    if not (envelope.get("ok") is True and isinstance(result, dict)
            and result.get("success") is True and isinstance(output, dict)):
        return "TakeScreenshot returned a failed or malformed response"
    # Both detectors compare against a pre-capture baseline. A queued request,
    # or an old path alone, is not evidence that a fresh image was observed.
    client = output.get("detectedScreenshot")
    for evidence, path_key, size_key in (
        (output, "fullName", "sizeBytes"), (client, "linuxPath", "size"),
    ):
        if not isinstance(evidence, dict):
            continue
        path, size = evidence.get(path_key), evidence.get(size_key)
        if (evidence.get("detected") is True and isinstance(path, str)
                and path.strip() and "\x00" not in path and type(size) is int and size > 0):
            return None
    return "TakeScreenshot did not confirm a fresh nonempty image"


def collect(call, screenshot=False):
    diagnostics = call("GetManiaScriptDiagnostics", {})
    report = {"diagnostics": diagnostics}
    envelope = diagnostics if isinstance(diagnostics, dict) else {}
    data = envelope.get("data")
    result = data.get("result") if isinstance(data, dict) else None
    output = result.get("output") if isinstance(result, dict) else None
    report["diagnosticsConfirmed"] = (
        envelope.get("ok") is True
        and isinstance(result, dict)
        and result.get("success") is True
        and isinstance(output, dict)
    )
    crash = output.get("crashDialogDetected") if report["diagnosticsConfirmed"] else None
    report["crashDialogDetected"] = crash if isinstance(crash, bool) else None
    # No native log getter exists. Never call missing text an empty/clean log.
    report["logAvailable"] = False
    report["nextStep"] = "Read the native Script debugger Log tab in a verified image before recovery. TakeScreenshot is viewport only; Openplanet/plugin UI needs a window/compositor capture (docs/window-screenshots.md). Image existence does not prove the debugger is visible. A dismissed prompt is not proof of script health."
    if screenshot:
        try:
            report["screenshot"] = call("TakeScreenshot", {"currentView": True, "hideOverlay": False})
            error = screenshot_error(report["screenshot"])
            if error:
                report["screenshotError"] = error
        except (OSError, subprocess.TimeoutExpired) as exc:
            report["screenshotError"] = str(exc)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshot", action="store_true", help="capture native viewport; Openplanet/plugin UI needs a separate window capture")
    parser.add_argument("--output", type=Path, help="also preserve JSON evidence at this path")
    args = parser.parse_args()
    process_failures = {}

    def call(tool, params):
        proc = subprocess.run([sys.executable, str(Path(__file__).with_name("call.py")), tool, json.dumps(params)], capture_output=True, text=True, timeout=40)
        if proc.returncode != 0:
            process_failures[tool] = {"returncode": proc.returncode, "stderr": proc.stderr[-2000:]}
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            return {"ok": False, "error": "call.py did not return JSON", "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr[-2000:]}

    try:
        report = collect(call, args.screenshot)
    except (OSError, subprocess.TimeoutExpired) as exc:
        report = {"diagnosticsConfirmed": False, "logAvailable": False, "error": str(exc)}
    for tool, metadata in process_failures.items():
        is_capture = tool == "TakeScreenshot"
        report["screenshotProcess" if is_capture else "diagnosticsProcess"] = metadata
        report.setdefault("screenshotError" if is_capture else "error",
                          f"{tool}: call.py exited with status {metadata['returncode']}")
    encoded = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(encoded + "\n")
    print(encoded)
    # A requested capture failure signals incomplete evidence without demoting diagnostics.
    return 0 if report.get("diagnosticsConfirmed") and "screenshotError" not in report and "error" not in report else 1


if __name__ == "__main__":
    sys.exit(main())
