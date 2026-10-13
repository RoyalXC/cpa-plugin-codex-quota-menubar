import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch


MODULE_PATH = Path(__file__).parents[1] / "menubar" / "runtime.py"
spec = importlib.util.spec_from_file_location("menubar_runtime", MODULE_PATH)
runtime_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime_module)


class MenubarRuntimeTests(unittest.TestCase):
    def test_runtime_identity_home_and_deployment_target(self):
        with patch.dict(runtime_module.os.environ, {}, clear=True):
            runtime = runtime_module.Runtime(architecture="arm64")
        self.assertEqual(runtime_module.VERSION, "0.5.0")
        self.assertEqual(runtime_module.BUNDLE_ID, "com.royalxc.codex-quota-menubar")
        self.assertEqual(runtime.home, Path.home() / "Library/Application Support/CodexQuotaMenubar")
        self.assertEqual(runtime.swift_target(), "arm64-apple-macosx13.0")
        self.assertTrue(runtime.app.is_relative_to(runtime.home / "versions" / "0.5.0"))
        self.assertEqual(runtime.build_metadata()["minimumSystemVersion"], "13.0")

    def test_zombie_process_is_absent_even_with_shortened_command(self):
        with patch.object(runtime_module.os, "waitpid", side_effect=ChildProcessError):
            with patch.object(runtime_module.sys, "platform", "linux"):
                with patch.object(runtime_module.subprocess, "run", return_value=Mock(stdout="Z QuotaMenubar\n")):
                    self.assertEqual(runtime_module.Runtime().process_state(4321), "absent")

    def test_native_process_identity_uses_full_path_not_ps_command(self):
        expected = str(runtime_module.Runtime().executable)
        def process_path(pid, buffer, size):
            buffer.value = expected.encode()
            return len(buffer.value)
        library = Mock(proc_pidpath=Mock(side_effect=process_path))
        with patch.object(runtime_module.sys, "platform", "darwin"), patch.object(runtime_module.ctypes, "CDLL", return_value=library):
            self.assertEqual(runtime_module.Runtime().process_command(4321), expected)

    def test_native_identity_errors_do_not_masquerade_as_exited_processes(self):
        library = Mock(proc_pidpath=Mock(return_value=0))
        with patch.object(runtime_module.sys, "platform", "darwin"), patch.object(runtime_module.ctypes, "CDLL", return_value=library):
            with patch.object(runtime_module.ctypes, "get_errno", return_value=runtime_module.errno.EACCES):
                with self.assertRaisesRegex(RuntimeError, "Cannot verify"):
                    runtime_module.Runtime().process_command(4321)

    def test_terminated_child_is_reaped_before_identity_lookup(self):
        with patch.object(runtime_module.os, "waitpid", return_value=(4321, 0)), patch.object(runtime_module.Runtime, "process_command") as command:
            self.assertEqual(runtime_module.Runtime().process_state(4321), "absent")
            command.assert_not_called()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "widget home"
        self.runtime = runtime_module.Runtime(self.home)

    def write_pid(self, pid, launched_at=None):
        self.runtime.run_dir.mkdir(parents=True, exist_ok=True)
        self.runtime.pid_file.write_text(json.dumps({
            "pid": pid,
            "executable": str(self.runtime.executable),
            "launchedAt": runtime_module.time.time() if launched_at is None else launched_at,
        }))

    def test_foreign_and_boolean_pids_are_refused(self):
        self.write_pid(4321)
        with patch.object(self.runtime, "process_command", return_value="/usr/bin/other-app"):
            with self.assertRaisesRegex(RuntimeError, "foreign process"):
                self.runtime.start()
        with patch.object(self.runtime, "process_command", return_value=str(self.runtime.executable) + "-lookalike"):
            with self.assertRaisesRegex(RuntimeError, "foreign process"):
                self.runtime.start()
        self.write_pid(True)
        with self.assertRaisesRegex(RuntimeError, "PID record is invalid"):
            self.runtime.stop()
        self.write_pid(1)
        with self.assertRaisesRegex(RuntimeError, "PID record is invalid"):
            self.runtime.stop()

    def test_start_is_idempotent_for_matching_and_pending_processes(self):
        self.write_pid(4321)
        with patch.object(self.runtime, "process_command", return_value=str(self.runtime.executable)):
            with patch.object(self.runtime, "build") as build, patch.object(runtime_module.subprocess, "Popen") as popen:
                self.assertEqual(self.runtime.start(), {"pid": 4321, "running": True, "alreadyRunning": True})
                build.assert_not_called()
                popen.assert_not_called()

        self.write_pid(4322, launched_at=runtime_module.time.time())
        with patch.object(self.runtime, "process_command", return_value=""):
            with patch.object(self.runtime, "build") as build, patch.object(runtime_module.subprocess, "Popen") as popen:
                self.assertEqual(self.runtime.start(), {"pid": 4322, "running": False, "pending": True})
                build.assert_not_called()
                popen.assert_not_called()

    def test_start_launches_detached_with_only_cpa_settings(self):
        self.home.mkdir()
        (self.runtime.home / "cpa-plugin").mkdir(parents=True)
        (self.runtime.home / "cpa-plugin/settings.json").write_text("{}")
        with patch.object(self.runtime, "build") as build, patch.object(runtime_module.subprocess, "Popen", return_value=Mock(pid=9876)) as popen:
            result = self.runtime.start()
        self.assertEqual(result, {"pid": 9876, "running": False, "pending": True})
        build.assert_called_once()
        arguments = popen.call_args
        self.assertEqual(arguments.args[0], [str(self.runtime.executable)])
        self.assertTrue(arguments.kwargs["start_new_session"])
        self.assertEqual(arguments.kwargs["stdin"], runtime_module.subprocess.DEVNULL)
        self.assertEqual(self.runtime.log_file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("never-read-secret", repr(arguments))

    def test_stop_signals_only_owned_process_and_waits_for_exit(self):
        self.write_pid(4321)
        with patch.object(self.runtime, "process_command", side_effect=[str(self.runtime.executable), ""]):
            with patch.object(runtime_module.os, "kill") as kill:
                result = self.runtime.stop()
        self.assertEqual(result, {"pid": 4321, "running": False, "stopped": True})
        kill.assert_called_once_with(4321, runtime_module.signal.SIGTERM)
        self.assertFalse(self.runtime.pid_file.exists())

    def test_stop_refuses_foreign_pid_without_signalling(self):
        self.write_pid(4321)
        with patch.object(self.runtime, "process_command", return_value="/usr/bin/other-app"):
            with patch.object(runtime_module.os, "kill") as kill:
                with self.assertRaisesRegex(RuntimeError, "foreign process"):
                    self.runtime.stop()
        kill.assert_not_called()

    def test_build_cache_includes_source_version_icon_and_stamp_is_outside_app(self):
        source = self.home / "QuotaMenubar.swift"
        source.parent.mkdir(parents=True)
        source.write_text("swift source one")
        icon = self.home / "QuotaMenubar.icns"
        icon.write_bytes(b"icns fixture one")
        self.runtime.home.mkdir(parents=True, exist_ok=True)
        with patch.object(runtime_module, "SOURCE", source), patch.object(runtime_module, "ICON_SOURCE", icon):
            def run(command, **kwargs):
                if command[0] == "xcrun":
                    executable = Path(command[command.index("-o") + 1])
                    executable.parent.mkdir(parents=True, exist_ok=True)
                    executable.write_bytes(b"mock binary")
                return Mock(returncode=0)

            with patch.object(runtime_module.subprocess, "run", side_effect=run) as run_mock:
                self.runtime.build()
                self.runtime.build()
                self.assertEqual(run_mock.call_count, 2)
                self.assertFalse(self.runtime.stamp.is_relative_to(self.runtime.app))
                bundled_icon = self.runtime.app / "Contents/Resources/QuotaMenubar.icns"
                self.assertEqual(bundled_icon.read_bytes(), icon.read_bytes())
                info = plistlib.loads((self.runtime.app / "Contents/Info.plist").read_bytes())
                self.assertEqual(info["CFBundleIconFile"], bundled_icon.name)
                original_calls = run_mock.call_count

                with patch.object(runtime_module, "VERSION", runtime_module.VERSION + ".test"):
                    self.runtime.build()
                self.assertGreater(run_mock.call_count, original_calls)
                version_calls = run_mock.call_count
                source.write_text("swift source two")
                self.runtime.build()
                self.assertGreater(run_mock.call_count, version_calls)
                source_calls = run_mock.call_count
                icon.write_bytes(b"icns fixture two")
                self.runtime.build()
                self.assertGreater(run_mock.call_count, source_calls)
                self.assertEqual(bundled_icon.read_bytes(), icon.read_bytes())

    def test_missing_icon_preserves_previous_app(self):
        previous_app = self.runtime.app / "Contents" / "previous-build.txt"
        previous_app.parent.mkdir(parents=True)
        previous_app.write_text("keep this build")
        with patch.object(runtime_module, "ICON_SOURCE", self.home / "missing.icns"):
            with patch.object(runtime_module.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "Native app icon is missing"):
                    self.runtime.build()
                run.assert_not_called()
        self.assertEqual(previous_app.read_text(), "keep this build")

    def test_failed_build_preserves_previous_app(self):
        source = self.home / "QuotaMenubar.swift"
        source.parent.mkdir(parents=True)
        source.write_text("swift source")
        previous_app = self.runtime.app / "Contents" / "previous-build.txt"
        previous_app.parent.mkdir(parents=True)
        previous_app.write_text("keep this build")

        def run(command, **kwargs):
            if command[0] == "xcrun":
                executable = Path(command[command.index("-o") + 1])
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_bytes(b"new binary")
            else:
                raise runtime_module.subprocess.CalledProcessError(1, command)
            return Mock(returncode=0)

        with patch.object(runtime_module, "SOURCE", source):
            with patch.object(runtime_module.subprocess, "run", side_effect=run):
                with self.assertRaises(runtime_module.subprocess.CalledProcessError):
                    self.runtime.build()
        self.assertEqual(previous_app.read_text(), "keep this build")
        self.assertEqual(len(list(self.runtime.app.parent.glob(".*.staging-*.app"))), 0)

    def test_build_refuses_to_replace_running_app(self):
        source = self.home / "QuotaMenubar.swift"
        source.parent.mkdir(parents=True)
        source.write_text("swift source")
        previous_app = self.runtime.app / "Contents" / "previous-build.txt"
        previous_app.parent.mkdir(parents=True)
        previous_app.write_text("keep this build")
        self.write_pid(4321)
        with patch.object(runtime_module, "SOURCE", source):
            with patch.object(self.runtime, "process_command", return_value=str(self.runtime.executable)):
                with patch.object(runtime_module.subprocess, "run") as run:
                    with self.assertRaisesRegex(RuntimeError, "process is running"):
                        self.runtime.build()
        run.assert_not_called()
        self.assertEqual(previous_app.read_text(), "keep this build")

    def test_status_matches_native_fields_and_rejects_injected_values(self):
        self.runtime.run_dir.mkdir(parents=True)
        self.runtime.status_file.write_text(json.dumps({
            "helperVersion": "0.5.0",
            "protocolVersion": 2,
            "visible": True,
            "popoverVisible": False,
            "quotaAvailable": True,
            "mode": "native",
            "launchMode": "independent",
            "eventsReceived": 7,
            "resolution": "desktop-auth",
            "stale": False,
            "loading": True,
            "updatedAt": 1780000000,
            "error": "CPA 配置或账号不可用。",
            "requestCount": 3,
            "refreshIntervalSeconds": 30.5,
            "windowTrackingEnabled": True,
            "running": "yes",
            "pid": True,
            "accountName": "private account",
            "rawUI": {"text": "private"},
        }))
        result = self.runtime.status()
        self.assertEqual(result, {
            "helperVersion": "0.5.0",
            "protocolVersion": 2,
            "visible": True,
            "popoverVisible": False,
            "quotaAvailable": True,
            "mode": "native",
            "launchMode": "independent",
            "eventsReceived": 7,
            "resolution": "desktop-auth",
            "stale": False,
            "loading": True,
            "updatedAt": 1780000000,
            "error": "CPA 配置或账号不可用。",
            "requestCount": 3,
            "refreshIntervalSeconds": 30.5,
            "windowTrackingEnabled": True,
            "running": False,
        })
        self.assertFalse(self.runtime.pid_file.exists())
        self.assertFalse(self.runtime.lock_file.exists())

        raw = json.loads(self.runtime.status_file.read_text())
        raw.update({
            "resolution": "1920x1080",
            "updatedAt": 1780000000.5,
            "error": "injected error with token",
            "requestCount": float("inf"),
            "refreshIntervalSeconds": True,
        })
        self.runtime.status_file.write_text(json.dumps(raw))
        result = self.runtime.status()
        self.assertNotIn("resolution", result)
        self.assertNotIn("updatedAt", result)
        self.assertNotIn("error", result)
        self.assertNotIn("requestCount", result)
        self.assertNotIn("refreshIntervalSeconds", result)

    def test_status_does_not_create_missing_directories(self):
        result = self.runtime.status()
        self.assertEqual(result, {"running": False})
        self.assertFalse(self.runtime.run_dir.exists())


if __name__ == "__main__":
    unittest.main()
