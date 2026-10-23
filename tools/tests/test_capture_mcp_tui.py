"""Headless harness checks: python3 -B -m unittest discover -s tools/tests -v."""

import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("capture_mcp_tui", Path(__file__).parents[1] / "capture_mcp_tui.py")
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class HarnessTests(unittest.TestCase):
    def test_real_desktop_and_forged_marker_are_refused(self):
        with patch.dict(os.environ, {"DISPLAY": ":0", "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}"}):
            self.assertFalse(capture.isolated_environment())
        with tempfile.TemporaryDirectory(prefix="isolated-run.test-") as directory:
            runtime = Path(directory)
            (runtime / "displayfd").write_text("991\n")
            with socket.socket(socket.AF_UNIX) as bus:
                bus.bind(str(runtime / "bus"))
                with patch.dict(os.environ, {"DISPLAY": ":991", "XDG_RUNTIME_DIR": directory,
                        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus",
                        "WAYLAND_DISPLAY": "unavailable", "WAYLAND_SOCKET": ""}):
                    self.assertFalse(capture.isolated_environment())

    def test_overwrite_guard_preserves_other_gallery_images(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(output=Path(directory), overwrite=False, details_key=None)
            original = args.output / "actual-live.png"
            original.write_bytes(b"original gallery image")
            capture.check_output(args)
            target = args.output / "live.png"
            target.write_bytes(b"existing capture")
            with self.assertRaisesRegex(RuntimeError, "--overwrite"):
                capture.check_output(args)
            self.assertEqual(target.read_bytes(), b"existing capture")
            args.overwrite = True
            capture.check_output(args)
            self.assertEqual(original.read_bytes(), b"original gallery image")

    def test_native_fixture_framing_errors_and_held_unicode_result(self):
        with capture.Fixture().running() as fixture:
            address = fixture.server_address

            def request(route, tool=None):
                with socket.create_connection(address, timeout=3) as connection:
                    message = {"id": "test-1", "route": route, "tool": tool, "input": {}}
                    connection.sendall((json.dumps(message) + "\n").encode())
                    with connection.makefile("rb") as reply:
                        envelope = json.loads(reply.readline())
                self.assertEqual((envelope["id"], envelope["route"], envelope["ok"]), ("test-1", route, True))
                return envelope["data"]

            self.assertEqual(request("status")["catalog"]["instance"], "tui-capture-fixture")
            self.assertEqual(len(request("catalog")["tools"]), 10)
            self.assertEqual(request("call", "GetMode")["result"]["output"]["mode"], "MapEditor")
            self.assertEqual(request("call", "ControlPlugin")["result"]["code"], "tool_busy")
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(request, "call", capture.PACK_TOOL)
                try:
                    self.assertTrue(fixture.started.wait(1))
                    self.assertFalse(pending.done())
                finally:
                    fixture.release.set()
                output = pending.result(timeout=2)["result"]["output"]
                self.assertIn("最後の行", output["zzFinalWrappedLine"])
                self.assertEqual(len(output["rows"]), 24)
            self.assertEqual(fixture.calls, ["GetMode", "ControlPlugin", capture.PACK_TOOL])
            self.assertFalse(fixture.failures)
        with self.assertRaises(OSError):
            socket.create_connection(address, timeout=0.1)

    def test_process_cleanup_reaches_child_in_separate_session_after_exception(self):
        command = [sys.executable, "-c", "import subprocess, sys, time; "
                   "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(90)'], start_new_session=True); "
                   "print(p.pid, flush=True); time.sleep(90)"]
        child_pid = None
        with self.assertRaisesRegex(RuntimeError, "capture failed"):
            with capture.managed_process(command, stdout=subprocess.PIPE, text=True) as parent:
                child_pid = int(parent.stdout.readline())
                parent.stdout.close()
                raise RuntimeError("capture failed")
        self.assertIsNotNone(parent.returncode)
        state = Path(f"/proc/{child_pid}/stat")
        if state.exists():
            self.assertEqual(state.read_text().rsplit(")", 1)[1].split()[0], "Z")

    def test_png_dimensions_are_read_from_pixels(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "capture.png"
            image.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 1668, 948))
            self.assertEqual(capture.png_dimensions(image), {"width": 1668, "height": 948})
            image.write_text("not pixels")
            with self.assertRaisesRegex(RuntimeError, "Invalid PNG"):
                capture.png_dimensions(image)


if __name__ == "__main__":
    unittest.main()
