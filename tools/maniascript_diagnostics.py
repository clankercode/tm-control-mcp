#!/usr/bin/env python3
"""Capture ManiaScript failure evidence without dismissing or restarting scripts."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def collect(call, screenshot=False):
    diagnostics = call("GetManiaScriptDiagnostics", {})
    report = {"diagnostics": diagnostics}
    result = diagnostics.get("data", {}).get("result", {})
    output = result.get("output", {})
    report["diagnosticsConfirmed"] = diagnostics.get("ok") is True and result.get("success") is True
    report["crashDialogDetected"] = output.get("crashDialogDetected") if report["diagnosticsConfirmed"] else None
    # No native log getter exists. Never call missing text an empty/clean log.
    report["logAvailable"] = False
    report["nextStep"] = "Read the native Script debugger Log tab in the captured image before recovery. A dismissed prompt is not proof of script health."
    if screenshot:
        report["screenshot"] = call("TakeScreenshot", {"currentView": True, "hideOverlay": False})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshot", action="store_true", help="capture current viewport with debugger overlays")
    parser.add_argument("--output", type=Path, help="also preserve JSON evidence at this path")
    args = parser.parse_args()

    def call(tool, params):
        proc = subprocess.run([sys.executable, str(Path(__file__).with_name("call.py")), tool, json.dumps(params)], capture_output=True, text=True, timeout=40)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            return {"ok": False, "error": "call.py did not return JSON", "returncode": proc.returncode, "stderr": proc.stderr[-2000:]}

    try:
        report = collect(call, args.screenshot)
    except (OSError, subprocess.TimeoutExpired) as exc:
        report = {"diagnosticsConfirmed": False, "logAvailable": False, "error": str(exc)}
    encoded = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(encoded + "\n")
    print(encoded)
    return 0 if report.get("diagnosticsConfirmed") else 1


if __name__ == "__main__":
    sys.exit(main())
