"""Offline regressions for process discovery and exact-window capture.

All process/X11/capture commands are mocked; these tests never contact a game.
"""

import contextlib
import io
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import tm_capture as capture  # noqa: E402
import tm_get_running_pids as discovery  # noqa: E402


def window(xid, name="Trackmania", width=1280, height=720):
    return {"xid": xid, "name": name, "x": 0, "y": 0,
            "width": width, "height": height}


def instance(pid, windows=None):
    return {"pid": pid, "game": "Trackmania.exe",
            "windows": windows if windows is not None else [window(pid + 1000)]}


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        # Fail closed if any test accidentally reaches an external command.
        self.run = self.enterContext(patch.object(
            subprocess, "run", side_effect=AssertionError("unexpected external command")))


class WindowDiscoveryTests(OfflineTestCase):
    def x11(self, candidates, owners, geometry=None):
        """A larger same-title foreign window exists, even if search misses it."""
        def run(cmd, **kwargs):
            args = cmd[1:]
            if args[:2] == ["search", "--pid"]:
                value = " ".join(map(str, candidates))
            elif args[:2] == ["search", "--name"]:
                value = "999"
            elif args[0] == "getwindowpid":
                value = owners[int(args[1])]
                if isinstance(value, Exception):
                    raise value
            elif args[0] == "getwindowname":
                value = "Trackmania"
            elif args[0] == "getwindowgeometry":
                value = (geometry or {}).get(int(args[-1]), "X=0 Y=0 WIDTH=1280 HEIGHT=720")
            else:
                raise AssertionError("unexpected command: %r" % cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout=str(value), stderr="")

        self.run.side_effect = run

    def test_same_title_foreign_window_is_never_merged(self):
        self.x11([101], {101: 42, 999: 43},
                 {999: "X=0 Y=0 WIDTH=3840 HEIGHT=2160"})
        self.assertEqual([w["xid"] for w in discovery._x11_windows(42)], [101])
        self.assertFalse(any("--name" in c.args[0] for c in self.run.call_args_list))

    def test_pid_search_results_are_independently_verified(self):
        self.x11([101, 102], {101: 42, 102: 43})
        self.assertEqual([w["xid"] for w in discovery._x11_windows(42)], [101])

    def test_missing_or_inaccessible_ownership_is_rejected(self):
        for owner in ("", "not-a-pid", "42 43", 0, -1, PermissionError(),
                      subprocess.CalledProcessError(1, ["xdotool"]),
                      subprocess.TimeoutExpired(["xdotool"], 5)):
            with self.subTest(owner=owner):
                self.x11([101], {101: owner})
                self.assertEqual(discovery._x11_windows(42), [])

    def test_title_only_window_is_not_used_when_pid_search_is_empty(self):
        self.x11([], {999: 42})
        self.assertEqual(discovery._x11_windows(42), [])

    def test_failed_search_returns_no_windows(self):
        for error in (FileNotFoundError(), subprocess.CalledProcessError(1, ["xdotool"]),
                      subprocess.TimeoutExpired(["xdotool"], 5)):
            with self.subTest(error=error):
                self.run.side_effect = error
                self.assertEqual(discovery._x11_windows(42), [])

    def test_malformed_geometry_does_not_abort_other_windows(self):
        for geometry in ("WIDTH=unknown HEIGHT=720", "X=0 Y=0"):
            with self.subTest(geometry=geometry):
                self.x11([101, 102], {101: 42, 102: 42}, {101: geometry})
                self.assertEqual([w["xid"] for w in discovery._x11_windows(42)], [102])

    def test_xdotool_checks_exit_status(self):
        self.x11([101], {101: 42})
        discovery._x11_windows(42)
        self.assertTrue(all(c.kwargs["check"] for c in self.run.call_args_list))


class WindowSelectionTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.find = self.enterContext(patch.object(capture, "find_instances"))
        self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def test_multiple_instances_require_disambiguation(self):
        self.find.return_value = [instance(42), instance(43)]
        for name in (None, "Trackmania"):
            with self.subTest(name=name), self.assertRaisesRegex(SystemExit, "ambiguous game instance"):
                capture.pick_window(name)

    def test_pid_selects_correct_instance(self):
        self.find.return_value = [instance(42), instance(43)]
        inst, win = capture.pick_window(None, pid=43)
        self.assertEqual((inst["pid"], win["xid"]), (43, 1043))

    def test_unique_name_selects_verified_window(self):
        self.find.return_value = [instance(42), instance(43, [window(1043, "Unique title")])]
        inst, win = capture.pick_window("unique")
        self.assertEqual((inst["pid"], win["xid"]), (43, 1043))

    def test_multiple_owned_windows_require_xid(self):
        self.find.return_value = [instance(42, [window(101), window(102, width=16, height=16)])]
        with self.assertRaisesRegex(SystemExit, "multiple X11 windows.*--xid"):
            capture.pick_window(None, pid=42)
        self.assertEqual(capture.pick_window(None, pid=42, xid=102)[1]["xid"], 102)

    def test_xid_can_disambiguate_instances(self):
        self.find.return_value = [instance(42), instance(43)]
        self.assertEqual(capture.pick_window(None, xid=1043)[0]["pid"], 43)

    def test_xid_cannot_override_selected_pid(self):
        self.find.return_value = [instance(42), instance(43)]
        with self.assertRaisesRegex(SystemExit, "no verified PID ownership"):
            capture.pick_window(None, pid=42, xid=1043)

    def test_missing_window_reports_ownership_requirement(self):
        self.find.return_value = [instance(42, [])]
        with self.assertRaisesRegex(SystemExit, "no X11 window with verified PID ownership"):
            capture.pick_window(None)

    def test_unknown_selector_does_not_fall_back(self):
        self.find.return_value = [instance(42)]
        for selectors in ({"pid": 43}, {"xid": 99}, {"name_sub": "other"}):
            with self.subTest(selectors=selectors), self.assertRaises(SystemExit):
                capture.pick_window(**({"name_sub": None} | selectors))

    def test_no_instances_is_an_error(self):
        self.find.return_value = []
        with self.assertRaisesRegex(SystemExit, "no running"):
            capture.pick_window(None)


class CaptureTests(OfflineTestCase):
    def test_ownership_is_rechecked_before_capture(self):
        for owner in (None, 43):
            with self.subTest(owner=owner), patch.object(capture, "get_window_pid", return_value=owner):
                with self.assertRaisesRegex(SystemExit, "no longer has verified ownership"):
                    capture.grab(101, "shot.png", 42)
        self.run.assert_not_called()

    def test_verified_window_is_captured_as_png(self):
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(capture, "get_window_pid", return_value=42):
            capture.grab(101, "shot", 42)
        self.run.assert_called_once_with(
            ["import", "-silent", "-window", "101", "png:shot"], capture_output=True, text=True)

    def test_capture_failure_is_reported(self):
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess([], 1, stdout="", stderr="window vanished")
        with patch.object(capture, "get_window_pid", return_value=42):
            with self.assertRaisesRegex(SystemExit, "import failed: window vanished"):
                capture.grab(101, "shot.png", 42)


class CaptureCliTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.find = self.enterContext(patch.object(capture, "find_instances", return_value=[instance(42)]))
        self.grab = self.enterContext(patch.object(capture, "grab"))
        self.sleep = self.enterContext(patch.object(capture.time, "sleep"))
        self.enterContext(patch.object(capture.time, "strftime", return_value="timestamp"))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def main(self, *args):
        with patch.object(sys, "argv", ["tm_capture.py", *args]):
            return capture.main()

    def test_numbered_filenames_with_and_without_suffix(self):
        for base, expected in (
            ("shot", ["shot-00.png", "shot-01.png", "shot-02.png"]),
            ("shots.png/shot.png", ["shots.png/shot-00.png", "shots.png/shot-01.png", "shots.png/shot-02.png"]),
            ("shot.PNG", ["shot-00.PNG", "shot-01.PNG", "shot-02.PNG"]),
        ):
            with self.subTest(base=base):
                self.grab.reset_mock()
                self.sleep.reset_mock()
                self.assertEqual(self.main("--frames", "3", "--interval-ms", "20", "-o", base), 0)
                self.assertEqual(self.grab.call_args_list, [call(1042, path, 42) for path in expected])
                self.assertEqual(self.sleep.call_args_list, [call(0.02), call(0.02)])

    def test_default_output_is_numbered(self):
        self.main("--frames", "2")
        self.assertEqual(self.grab.call_args_list, [call(1042, "/tmp/tm-capture-timestamp-00.png", 42),
                                                  call(1042, "/tmp/tm-capture-timestamp-01.png", 42)])

    def test_single_frame_preserves_explicit_filename(self):
        self.main("-o", "shot", "--interval-ms", "0")
        self.grab.assert_called_once_with(1042, "shot", 42)
        self.sleep.assert_not_called()

    def test_invalid_arguments_fail_before_discovery_or_capture(self):
        for flag, values in (("--frames", ("0", "-1", "1.5")),
                             ("--interval-ms", ("-1", "1.5")),
                             ("--pid", ("0", "-1")), ("--xid", ("0", "-1"))):
            for value in values:
                with self.subTest(flag=flag, value=value), self.assertRaises(SystemExit) as error:
                    self.main(flag, value)
                self.assertEqual(error.exception.code, 2)
        self.find.assert_not_called()
        self.grab.assert_not_called()
        self.run.assert_not_called()

    def test_cli_ambiguity_never_captures(self):
        self.find.return_value = [instance(42), instance(43)]
        with self.assertRaisesRegex(SystemExit, "ambiguous"):
            self.main()
        self.grab.assert_not_called()

    def test_cli_selectors_are_applied(self):
        self.find.return_value = [instance(42), instance(43)]
        self.main("--pid", "43", "--xid", "1043", "-o", "shot.png")
        self.grab.assert_called_once_with(1043, "shot.png", 43)

    def test_list_propagates_discovery_status(self):
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess([], 1)
        self.assertEqual(self.main("--list"), 1)
        self.find.assert_not_called()
        self.grab.assert_not_called()


class ProcessDiscoveryTests(OfflineTestCase):
    def test_start_time_exit_or_access_race_skips_only_affected_process(self):
        paths = [Path("/proc/42"), Path("/proc/43"), Path("/proc/self")]
        for error in (FileNotFoundError(), ProcessLookupError(), PermissionError(),
                      OSError("unreadable"), ValueError("incomplete stat"), IndexError()):
            with self.subTest(error=error), patch.object(discovery.Path, "iterdir", return_value=iter(paths)), \
                    patch.object(discovery, "_cmdline", return_value=["C:\\Games\\Trackmania.exe"]), \
                    patch.object(discovery, "_start_time_s", side_effect=[error, 1000]), \
                    patch.object(discovery, "_x11_windows", return_value=[]) as windows:
                found = discovery.find_instances()
                self.assertEqual([i["pid"] for i in found], [43])
                windows.assert_called_once_with(43)

    def test_cmdline_exit_or_access_race_returns_empty(self):
        for error in (FileNotFoundError(), PermissionError(), ProcessLookupError()):
            with self.subTest(error=error), patch.object(discovery.Path, "read_bytes", side_effect=error):
                self.assertEqual(discovery._cmdline(Path("/proc/42")), [])

    def test_inaccessible_cmdline_does_not_abort_discovery(self):
        with patch.object(discovery.Path, "iterdir", return_value=iter([Path("/proc/42"), Path("/proc/43")])), \
                patch.object(discovery, "_cmdline", side_effect=[[], ["Trackmania.exe"]]), \
                patch.object(discovery, "_start_time_s", return_value=1000), \
                patch.object(discovery, "_x11_windows", return_value=[]):
            self.assertEqual([i["pid"] for i in discovery.find_instances()], [43])


if __name__ == "__main__":
    unittest.main()
