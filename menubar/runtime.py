#!/usr/bin/env python3
"""Build and control the native macOS quota menubar application."""

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


VERSION = "0.5.0"
BUNDLE_ID = "com.royalxc.codex-quota-menubar"
APP_NAME = "Codex Quota Menubar.app"
EXECUTABLE_NAME = "QuotaMenubar"
PENDING_SECONDS = 15
STOP_TIMEOUT_SECONDS = 5
STOP_POLL_SECONDS = 0.1
STATUS_FIELDS = (
    "helperVersion",
    "protocolVersion",
    "pid",
    "running",
    "visible",
    "popoverVisible",
    "quotaAvailable",
    "eventsReceived",
    "mode",
    "launchMode",
    "resolution",
    "stale",
    "loading",
    "updatedAt",
    "error",
    "requestCount",
    "refreshIntervalSeconds",
    "windowTrackingEnabled",
)
BOOLEAN_FIELDS = {
    "running",
    "visible",
    "popoverVisible",
    "quotaAvailable",
    "stale",
    "loading",
    "windowTrackingEnabled",
}
NUMBER_FIELDS = {"eventsReceived", "requestCount", "refreshIntervalSeconds", "protocolVersion"}
RESOLUTIONS = {"recent-request", "last-official-request", "desktop-auth", "single-account", "selected-account", "third-party", "ambiguous", "unavailable"}
SAFE_ERRORS = {
    "",
    "CPA 配置或账号不可用。",
    "额度接口暂时不可用。",
    "账号认证已过期，请在 CPA 重新登录。",
}

CORE_SOURCE = Path(__file__).resolve().parent / "native" / "QuotaEngine.swift"
IPC_SOURCE = Path(__file__).resolve().parent / "native" / "QuotaIPC.swift"
SOURCE = Path(__file__).resolve().parent / "native" / "QuotaMenubar.swift"
ICON_SOURCE = Path(__file__).resolve().parent / "assets" / "QuotaMenubar.icns"


class Runtime:
    def __init__(self, home=None, architecture=None, deployment_target="13.0", macos27_sdk=False):
        configured_home = home or os.environ.get("CODEX_ACCOUNT_WIDGET_HOME", "~/Library/Application Support/CodexQuotaMenubar")
        self.home = Path(configured_home).expanduser().resolve()
        self.app = self.home / "versions" / VERSION / APP_NAME
        self.executable = self.app / "Contents" / "MacOS" / EXECUTABLE_NAME
        self.stamp = self.home / "builds" / VERSION / "build-stamp.json"
        self.run_dir = self.home / "run" / "menubar"
        self.status_file = self.run_dir / "status.json"
        self.pid_file = self.run_dir / "pid.json"
        self.lock_file = self.run_dir / "control.lock"
        self.log_file = self.run_dir / "native.log"
        self.architecture = architecture or platform.machine()
        self.deployment_target = deployment_target
        self.macos27_sdk = macos27_sdk

    def lock(self):
        self.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self.lock_file, os.O_CREAT | os.O_RDWR, 0o600)
        os.chmod(self.lock_file, 0o600)
        return descriptor

    def build_metadata(self):
        return {
            "version": VERSION,
            "bundleId": BUNDLE_ID,
            "swiftVersion": "5",
            "minimumSystemVersion": self.deployment_target,
            "architecture": self.architecture,
            "macos27SDK": self.macos27_sdk,
            "optimization": "-O",
            "frameworks": ["AppKit"],
            "info": {
                "LSUIElement": True,
                "NSHighResolutionCapable": True,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                "CFBundleIconFile": "QuotaMenubar.icns",
            },
            "codesign": "ad-hoc",
        }

    def build_digest(self):
        digest = hashlib.sha256()
        digest.update(SOURCE.read_bytes())
        digest.update(CORE_SOURCE.read_bytes())
        digest.update(IPC_SOURCE.read_bytes())
        digest.update(ICON_SOURCE.read_bytes())
        digest.update(json.dumps(self.build_metadata(), sort_keys=True, separators=(",", ":")).encode())
        return digest.hexdigest()

    def build(self):
        if not SOURCE.is_file():
            raise RuntimeError(f"Native source is missing: {SOURCE}")
        if not ICON_SOURCE.is_file():
            raise RuntimeError(f"Native app icon is missing: {ICON_SOURCE}")
        current_digest = self.build_digest()
        try:
            stamp = json.loads(self.stamp.read_text())
        except (OSError, ValueError):
            stamp = {}
        if stamp.get("digest") == current_digest and self.executable.is_file():
            return self.app

        record = self.read_pid_record()
        if record:
            process_state = self.require_owned_process(record["pid"])
            age = time.time() - record.get("launchedAt", 0)
            if process_state == "matching" or (process_state == "absent" and 0 <= age <= PENDING_SECONDS):
                raise RuntimeError("Refusing to replace the menubar app while its process is running or starting")

        self.app.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        staging_app = Path(tempfile.mkdtemp(prefix=f".{APP_NAME}.staging-", suffix=".app", dir=self.app.parent))
        backup_app = self.app.with_name(f".{APP_NAME}.backup-{uuid.uuid4().hex}")
        try:
            executable = staging_app / "Contents" / "MacOS" / EXECUTABLE_NAME
            executable.parent.mkdir(parents=True, mode=0o700)
            with tempfile.TemporaryDirectory() as source_directory:
                main_source = Path(source_directory) / "main.swift"
                shutil.copy2(SOURCE, main_source)
                command = ["xcrun", "swiftc", "-swift-version", "5"]
                target = self.swift_target()
                command.extend(["-target", target] if target else ["-mmacosx-version-min", self.deployment_target])
                command.append("-O")
                if self.macos27_sdk:
                    command.extend(["-D", "QUOTA_MACOS27_SDK"])
                command.extend(["-framework", "AppKit", "-lsqlite3", str(main_source), str(CORE_SOURCE), str(IPC_SOURCE), "-o", str(executable)])
                subprocess.run(
                    command,
                    check=True,
                )
            resources = staging_app / "Contents" / "Resources"
            resources.mkdir(mode=0o700)
            shutil.copy2(ICON_SOURCE, resources / "QuotaMenubar.icns")
            info = self.build_metadata()["info"]
            info.update({"CFBundleExecutable": EXECUTABLE_NAME, "CFBundleIdentifier": BUNDLE_ID, "CFBundleName": "Codex Quota Menubar", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION, "LSMinimumSystemVersion": self.deployment_target})
            with (staging_app / "Contents" / "Info.plist").open("wb") as output:
                plistlib.dump(info, output)
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(staging_app)], check=True)

            if self.app.exists():
                os.replace(self.app, backup_app)
            try:
                os.replace(staging_app, self.app)
            except Exception:
                if backup_app.exists():
                    os.replace(backup_app, self.app)
                raise
            if backup_app.exists():
                shutil.rmtree(backup_app, ignore_errors=True)
        finally:
            if staging_app.exists():
                shutil.rmtree(staging_app, ignore_errors=True)

        self.stamp.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary_stamp = self.stamp.with_suffix(".tmp")
        temporary_stamp.write_text(json.dumps({"digest": current_digest, "version": VERSION}, sort_keys=True) + "\n")
        temporary_stamp.chmod(0o600)
        temporary_stamp.replace(self.stamp)
        return self.app

    def swift_target(self):
        if self.architecture not in {"arm64", "x86_64"}:
            return None
        return f"{self.architecture}-apple-macosx{self.deployment_target}"

    @staticmethod
    def valid_pid(value):
        return isinstance(value, int) and not isinstance(value, bool) and value > 1

    def read_pid_record(self):
        try:
            record = json.loads(self.pid_file.read_text())
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as error:
            raise RuntimeError("PID record is unreadable") from error
        if not isinstance(record, dict) or not self.valid_pid(record.get("pid")):
            raise RuntimeError("PID record is invalid")
        if record.get("executable") != str(self.executable):
            raise RuntimeError("PID record belongs to a different executable")
        launched_at = record.get("launchedAt", 0)
        if not isinstance(launched_at, (int, float)) or isinstance(launched_at, bool):
            raise RuntimeError("PID record is invalid")
        return record

    def write_pid_record(self, pid, launched_at=None):
        self.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.pid_file.with_suffix(".tmp")
        temporary.write_text(json.dumps({"pid": pid, "executable": str(self.executable), "launchedAt": launched_at or time.time()}, sort_keys=True) + "\n")
        temporary.chmod(0o600)
        temporary.replace(self.pid_file)

    def process_command(self, pid):
        if sys.platform == "darwin":
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            function = library.proc_pidpath
            function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            function.restype = ctypes.c_int
            buffer = ctypes.create_string_buffer(4096)
            ctypes.set_errno(0)
            result = function(pid, buffer, len(buffer))
            if result > 0:
                return os.fsdecode(buffer.value)
            if ctypes.get_errno() in {errno.ESRCH, errno.ENOENT}:
                return ""
            raise RuntimeError("Cannot verify native process identity")
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=,comm="], capture_output=True, text=True, check=False)
        fields = result.stdout.strip().split(None, 1)
        if len(fields) != 2 or fields[0].startswith("Z"):
            return ""
        return fields[1]

    def process_state(self, pid):
        try:
            child, _ = os.waitpid(pid, os.WNOHANG)
            if child == pid:
                return "absent"
        except ChildProcessError:
            pass
        command = self.process_command(pid)
        if not command:
            return "absent"
        expected = str(self.executable)
        if command == expected:
            return "matching"
        return "foreign"

    def require_owned_process(self, pid):
        state = self.process_state(pid)
        if state == "foreign":
            raise RuntimeError(f"Refusing to control foreign process with PID {pid}")
        return state

    def start(self):
        record = self.read_pid_record()
        if record:
            state = self.require_owned_process(record["pid"])
            if state == "matching":
                return {"pid": record["pid"], "running": True, "alreadyRunning": True}
            age = time.time() - record.get("launchedAt", 0)
            if state == "absent" and 0 <= age <= PENDING_SECONDS:
                return {"pid": record["pid"], "running": False, "pending": True}
            self.pid_file.unlink(missing_ok=True)

        self.build()
        self.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self.log_file, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        os.chmod(self.log_file, 0o600)
        with os.fdopen(descriptor, "ab") as log:
            process = subprocess.Popen(
                [str(self.executable)],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                env={**os.environ, "CODEX_ACCOUNT_WIDGET_HOME": str(self.home)},
                start_new_session=True,
                close_fds=True,
            )
        self.write_pid_record(process.pid)
        return {"pid": process.pid, "running": False, "pending": True}

    def stop(self):
        record = self.read_pid_record()
        if not record:
            return {"pid": None, "running": False, "stopped": True}
        pid = record["pid"]
        state = self.require_owned_process(pid)
        if state == "absent":
            self.pid_file.unlink(missing_ok=True)
            return {"pid": pid, "running": False, "stopped": True}
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + STOP_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            state = self.require_owned_process(pid)
            if state == "absent":
                self.pid_file.unlink(missing_ok=True)
                return {"pid": pid, "running": False, "stopped": True}
            time.sleep(STOP_POLL_SECONDS)
        return {"pid": pid, "running": True, "stopped": False, "error": "Timed out waiting for process to exit"}

    def status(self):
        try:
            raw = json.loads(self.status_file.read_text())
        except (OSError, ValueError):
            raw = {}
        if not isinstance(raw, dict):
            raw = {}
        result = {}
        for field in STATUS_FIELDS:
            value = raw.get(field)
            if field in {"pid", "running"}:
                continue
            if field in BOOLEAN_FIELDS:
                if isinstance(value, bool):
                    result[field] = value
            elif field == "helperVersion" and isinstance(value, str) and len(value) <= 32 and value.replace(".", "").isalnum():
                result[field] = value
            elif field in NUMBER_FIELDS | {"updatedAt"}:
                is_epoch = field == "updatedAt"
                if (
                    isinstance(value, int if is_epoch else (int, float))
                    and not isinstance(value, bool)
                    and value >= 0
                    and (is_epoch or math.isfinite(value))
                ):
                    result[field] = value
            elif field == "mode" and value == "native":
                result[field] = value
            elif field == "launchMode" and isinstance(value, str) and value in {"independent", "cpa-managed"}:
                result[field] = value
            elif field == "resolution" and isinstance(value, str) and value in RESOLUTIONS:
                result[field] = value
            elif field == "error" and isinstance(value, str) and value in SAFE_ERRORS:
                result[field] = value

        record = None
        try:
            record = self.read_pid_record()
        except RuntimeError:
            pass
        if record:
            result["pid"] = record["pid"]
            result["running"] = self.process_state(record["pid"]) == "matching"
        else:
            result.setdefault("running", False)
        return result

    def self_test(self):
        self.build()
        result = subprocess.run([str(self.executable), "--self-test"], capture_output=True, text=True, check=True)
        try:
            data = json.loads(result.stdout)
        except ValueError as error:
            raise RuntimeError("Native self-test did not return valid JSON") from error
        if not isinstance(data, dict):
            raise RuntimeError("Native self-test JSON must be an object")
        return data


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "start", "stop", "status", "self-test"))
    parser.add_argument("--arch", dest="architecture")
    parser.add_argument("--deployment-target", default="13.0")
    parser.add_argument("--macos27-sdk", action="store_true")
    args = parser.parse_args(argv)
    runtime = Runtime(architecture=args.architecture, deployment_target=args.deployment_target, macos27_sdk=args.macos27_sdk)
    if args.action == "status":
        try:
            descriptor = os.open(runtime.lock_file, os.O_RDONLY)
        except FileNotFoundError:
            result = runtime.status()
        else:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_SH)
                result = runtime.status()
            finally:
                os.close(descriptor)
    else:
        descriptor = runtime.lock()
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if args.action == "build":
                result = {"built": str(runtime.build())}
            elif args.action == "start":
                result = runtime.start()
            elif args.action == "stop":
                result = runtime.stop()
            else:
                result = runtime.self_test()
        finally:
            os.close(descriptor)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
