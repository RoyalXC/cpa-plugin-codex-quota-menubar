"""Native ABI tests for the CPA store plugin; all files live in temporary dirs."""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import socket
import subprocess
import tempfile
import time
import unittest
import zipfile


ROOT = Path(__file__).parents[1]
SOURCE = ROOT / "plugin" / "QuotaPlugin.m"
VERSION = "0.5.0"


HELPER = r'''#!/usr/bin/python3
import os, select, socket, sys, time
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
home, sockpath, eventfd = args["--home"], args["--socket-path"], int(args["--event-fd"])
os.makedirs(home, exist_ok=True)
with open(os.path.join(home, "helper-starts"), "a") as f: f.write("start %d\n" % os.getpid())
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try: os.unlink(sockpath)
except FileNotFoundError: pass
srv.bind(sockpath); os.chmod(sockpath, 0o600); srv.listen()
os.write(eventfd, b"Q2M:0.5.0\n")
srv.setblocking(False); os.set_blocking(eventfd, False)
peers = []
running = True
while running:
    ready, _, _ = select.select([eventfd, srv] + peers, [], [], .1)
    if eventfd in ready:
        try: msg = os.read(eventfd, 1)
        except BlockingIOError: msg = b""
        if msg == b"U":
            with open(os.path.join(home, "usage-events"), "a") as f: f.write("U\n")
        elif msg == b"D": running = False
        elif msg == b"": running = False
    if srv in ready:
        conn, _ = srv.accept()
        try:
            if conn.recv(2) == b"Q2":
                with open(os.path.join(home, "helper-connections"), "a") as f: f.write("Q2\n")
                conn.sendall(b"Q2I:0.5.0\n"); peers.append(conn)
            else: conn.close()
        except OSError: conn.close()
    for peer in list(peers):
        if peer in ready:
            try:
                if not peer.recv(1): peers.remove(peer); peer.close()
            except OSError: peers.remove(peer); peer.close()
    quit_peer = os.path.join(home, "quit-independent")
    if os.path.exists(quit_peer):
        os.unlink(quit_peer)
        for peer in list(peers):
            try: peer.sendall(b"D")
            except OSError: pass
            peers.remove(peer); peer.close()
    control = os.path.join(home, "quit-helper")
    if os.path.exists(control):
        os.unlink(control); os.write(eventfd, b"D"); running = False
srv.close()
try: os.unlink(sockpath)
except OSError: pass
'''


class Buffer(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_size_t)]


class HostAPI(ctypes.Structure):
    _fields_ = [("abi_version", ctypes.c_uint32), ("host_ctx", ctypes.c_void_p),
                ("call", ctypes.c_void_p), ("free_buffer", ctypes.c_void_p)]


class PluginAPI(ctypes.Structure):
    _fields_ = [("abi_version", ctypes.c_uint32), ("call", ctypes.c_void_p),
                ("free_buffer", ctypes.c_void_p), ("shutdown", ctypes.c_void_p)]


def tree_sha256(root):
    digest_input = bytearray()

    def visit(directory, relative=""):
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            child_relative = f"{relative}/{entry.name}" if relative else entry.name
            encoded = child_relative.encode("utf-8")
            mode = entry.stat(follow_symlinks=False).st_mode & 0o7777
            digest_input.extend(struct.pack("<Q", len(encoded))); digest_input.extend(encoded)
            digest_input.extend(struct.pack("<I", mode))
            if entry.is_dir(follow_symlinks=False):
                digest_input.extend(b"d"); visit(entry.path, child_relative)
            elif entry.is_file(follow_symlinks=False):
                content = Path(entry.path).read_bytes()
                digest_input.extend(b"f"); digest_input.extend(struct.pack("<Q", len(content))); digest_input.extend(content)
            elif entry.is_symlink():
                target = os.readlink(entry.path).encode("utf-8")
                digest_input.extend(b"l"); digest_input.extend(struct.pack("<Q", len(target))); digest_input.extend(target)
            else:
                raise ValueError(f"unsupported fixture app entry {entry.path}")

    visit(root)
    return hashlib.sha256(digest_input).hexdigest()


class NativePluginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys_platform() != "darwin":
            raise unittest.SkipTest("native CPA plugin requires macOS Foundation and codesign")
        cls.temp_root = tempfile.TemporaryDirectory(prefix="quota-native-tests-")
        cls.build_root = Path(cls.temp_root.name)
        cls.zip_path = cls.make_payload(cls.build_root / "fixture")
        cls.library_path = cls.compile_plugin(cls.zip_path, cls.build_root / "plugin.dylib")

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temp_root"):
            cls.temp_root.cleanup()

    @classmethod
    def make_payload(cls, base):
        app = base / "Codex Quota Menubar.app"
        executable = app / "Contents" / "MacOS" / "QuotaMenubar"
        executable.parent.mkdir(parents=True)
        executable.write_text(HELPER)
        executable.chmod(0o755)
        with (app / "Contents" / "Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleExecutable": "QuotaMenubar", "CFBundleIdentifier": "test.codex.quota",
                           "CFBundleName": "Codex Quota Menubar", "CFBundlePackageType": "APPL"}, f)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        archive = base / "payload.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
            for path in app.rglob("*"):
                if path.is_file(): zf.write(path, path.relative_to(base))
        return archive

    @classmethod
    def compile_plugin(cls, archive, output, digest=None):
        payload = archive.read_bytes()
        digest = digest or hashlib.sha256(payload).hexdigest()
        arch = "arm64" if os.uname().machine == "arm64" else "amd64"
        header = output.parent / "QuotaPayload.h"
        values = ",".join(str(b) for b in payload)
        app_hash = tree_sha256(archive.parent / "Codex Quota Menubar.app")
        header.write_text("#pragma once\n#include <stddef.h>\n#define QUOTA_VERSION \"0.5.0\"\n"
                          f"#define QUOTA_PAYLOAD_SHA256 \"{digest}\"\n#define QUOTA_PAYLOAD_ARCH \"{arch}\"\n"
                          f"#define QUOTA_APP_TREE_SHA256 \"{app_hash}\"\n"
                          f"const unsigned char quota_payload_bytes[] = {{{values}}};\n"
                          f"const size_t quota_payload_size = {len(payload)};\n")
        subprocess.run(["clang", "-dynamiclib", "-fobjc-arc", "-Wno-deprecated-declarations",
                        "-framework", "Foundation", "-I", str(output.parent), str(SOURCE), "-o", str(output)],
                       check=True, capture_output=True, text=True)
        return output

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="quota-native-case-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "plugin-data"
        self.lib = ctypes.CDLL(str(self.library_path))
        self.api = PluginAPI()
        self.lib.cliproxy_plugin_init.argtypes = [ctypes.POINTER(HostAPI), ctypes.POINTER(PluginAPI)]
        self.lib.cliproxy_plugin_init.restype = ctypes.c_int
        self.assertEqual(self.lib.cliproxy_plugin_init(ctypes.byref(HostAPI(1, None, None, None)), ctypes.byref(self.api)), 0)
        self.call_fn = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                        ctypes.POINTER(Buffer))(self.api.call)
        self.free_fn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)(self.api.free_buffer)

    def rpc(self, method, payload=None):
        encoded = json.dumps(payload or {}).encode()
        buffer = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(encoded) if encoded else None
        response = Buffer()
        rc = self.call_fn(method.encode(), buffer, len(encoded), ctypes.byref(response))
        result = json.loads(ctypes.string_at(response.ptr, response.len))
        self.free_fn(response.ptr, response.len)
        return rc, result

    def register(self, **settings):
        yaml = "\n".join(f"{key}: {value}" for key, value in settings.items())
        return self.rpc("plugin.register", {"schema_version": 1, "config_yaml": base64.b64encode(yaml.encode()).decode()})

    def wait_until(self, predicate, timeout=6):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate(): return True
            time.sleep(.05)
        return predicate()

    def test_deployment_ready_filter_duplicate_register_and_quiesce_reregister(self):
        rc, response = self.register(dataDir=self.home)
        self.assertEqual(rc, 0, response)
        self.assertTrue(response["ok"])
        self.assertTrue(self.wait_until(lambda: (self.home / "payloads").exists()))
        installed = list((self.home / "payloads").glob("*/Codex Quota Menubar.app"))
        self.assertEqual(len(installed), 1)
        settings = json.loads((self.home / "cpa-plugin/settings.json").read_text())
        self.assertTrue(Path(settings["cpaHome"]).is_absolute())
        starts = self.home / "helper-starts"
        self.assertTrue(self.wait_until(starts.exists))
        before = starts.read_text().count("start")
        self.rpc("usage.handle", {"record": {"generate": False}})
        self.rpc("usage.handle", {"record": {"generate": True}})
        events = self.home / "usage-events"
        self.assertTrue(self.wait_until(lambda: events.exists() and events.read_text().count("U") == 1))
        self.register(dataDir=self.home)
        time.sleep(.2)
        self.assertEqual(starts.read_text().count("start"), before)
        self.rpc("plugin.quiesce")
        self.assertTrue(self.wait_until(lambda: not self.socket_exists()))
        rc, response = self.register(dataDir=self.home)
        self.assertEqual(rc, 0, response)
        self.assertTrue(self.wait_until(lambda: starts.read_text().count("start") == before + 1))
        self.rpc("plugin.shutdown")

    def socket_exists(self):
        # The socket's parent is derived from the same algorithm used by the plugin.
        key = hashlib.sha256(str(self.home).encode()).hexdigest()[:12]
        return Path(f"/tmp/cqm-{os.getuid()}-{key}/events-v2.sock").exists()

    def test_existing_user_settings_are_preserved(self):
        settings_dir = self.home / "cpa-plugin"
        settings_dir.mkdir(parents=True)
        (settings_dir / "settings.json").write_text(json.dumps({"selectedAuthIndex": "keep-me", "other": 7}))
        rc, response = self.register(dataDir=self.home, authDir=self.base / "auth", managementPort=18090)
        self.assertEqual(rc, 0, response)
        stored = json.loads((settings_dir / "settings.json").read_text())
        self.assertEqual(stored["selectedAuthIndex"], "keep-me")
        self.assertEqual(stored["other"], 7)
        self.assertEqual(stored["managementPort"], 18090)
        self.rpc("plugin.shutdown")

    def test_core_normalized_config_skips_host_fields_and_store_manifest(self):
        yaml = f"""enabled: true
priority: 3
dataDir: {self.home}
cpaHome: {self.base / 'cpa-home'}
authDir: {self.base / 'auth'}
managementPort: 18090
store:
  schema-version: 1
  id: codex-quota-menubar
  name: Codex Quota Menubar
  version: 0.5.0
  release-tag: v0.5.0
  repository: https://github.com/RoyalXC/cpa-plugin-codex-quota-menubar
  source-id: official
  source-name: CPA Plugin Store
  source-url: https://plugins.example.test/index.yaml
  tags:
    - quota
    - codex
  install:
    type: github-release
"""
        rc, response = self.rpc("plugin.register", {"schema_version": 6,
            "config_yaml": base64.b64encode(yaml.encode()).decode()})
        self.assertEqual(rc, 0, response)
        settings = json.loads((self.home / "cpa-plugin/settings.json").read_text())
        self.assertEqual(settings["cpaHome"], str(self.base / "cpa-home"))
        self.assertEqual(settings["authDir"], str(self.base / "auth"))
        self.assertEqual(settings["managementPort"], 18090)
        self.rpc("plugin.shutdown")

    def test_user_quit_pauses_and_changed_configuration_restarts(self):
        self.assertEqual(self.register(dataDir=self.home)[0], 0)
        starts = self.home / "helper-starts"
        self.assertTrue(self.wait_until(starts.exists))
        (self.home / "quit-helper").touch()
        self.assertTrue(self.wait_until(lambda: not self.socket_exists()))
        count = starts.read_text().count("start")
        time.sleep(1.3)
        self.assertEqual(starts.read_text().count("start"), count)
        other_home = self.base / "changed-data"
        rc, response = self.rpc("plugin.reconfigure", {"schema_version": 1,
            "config_yaml": base64.b64encode(f"dataDir: {other_home}".encode()).decode()})
        self.assertEqual(rc, 0, response)
        self.assertTrue(self.wait_until(lambda: (other_home / "helper-starts").exists()))
        self.rpc("plugin.shutdown")

    def test_crashed_owned_helper_is_reaped_and_restarted(self):
        rc, response = self.register(dataDir=self.home)
        self.assertEqual(rc, 0, response)
        starts = self.home / "helper-starts"
        self.assertTrue(self.wait_until(starts.exists))
        first_pid = int(starts.read_text().splitlines()[0].split()[1])
        os.kill(first_pid, 9)
        self.assertTrue(self.wait_until(lambda: starts.exists() and starts.read_text().count("start") == 2))
        self.assertNotEqual(int(starts.read_text().splitlines()[1].split()[1]), first_pid)
        self.rpc("plugin.shutdown")

    def test_reconfigure_changes_home_in_order_and_payload_reuse_is_signed(self):
        self.assertEqual(self.register(dataDir=self.home)[0], 0)
        original = next((self.home / "payloads").glob("*/Codex Quota Menubar.app"))
        rc, response = self.rpc("plugin.reconfigure", {"schema_version": 1,
            "config_yaml": base64.b64encode(f"dataDir: {self.home}\ncpaHome: {self.base / 'cpa'}".encode()).decode()})
        self.assertEqual(rc, 0, response)
        self.assertTrue(self.wait_until(lambda: (self.home / "helper-starts").read_text().count("start") >= 2))
        self.assertEqual(original, next((self.home / "payloads").glob("*/Codex Quota Menubar.app")))
        self.rpc("plugin.shutdown")

    def test_tampered_installed_app_is_refused(self):
        rc, response = self.register(dataDir=self.home)
        self.assertEqual(rc, 0, response)
        self.rpc("plugin.shutdown")
        app = next((self.home / "payloads").glob("*/Codex Quota Menubar.app"))
        executable = app / "Contents/MacOS/QuotaMenubar"
        executable.write_text(executable.read_text() + "\n# changed\n")
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        identity = app.parent.name
        zip_digest = identity.split("-", 1)[1]
        (app.parent / "payload.sha256").write_text(f"{zip_digest}\n{tree_sha256(app)}\n")
        rc, response = self.register(dataDir=self.home)
        self.assertNotEqual(rc, 0)
        self.assertRegex(response["error"]["message"], "manifest|code-signature|pinned")

    def test_independent_plugin_instance_connects_without_owning_helper(self):
        self.assertEqual(self.register(dataDir=self.home)[0], 0)
        second_path = self.build_root / "second.dylib"
        shutil.copy2(self.library_path, second_path)
        second_lib = ctypes.CDLL(str(second_path)); second_api = PluginAPI()
        self.assertEqual(second_lib.cliproxy_plugin_init(ctypes.byref(HostAPI(1, None, None, None)), ctypes.byref(second_api)), 0)
        call = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                ctypes.POINTER(Buffer))(second_api.call)
        free = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)(second_api.free_buffer)
        body = json.dumps({"schema_version": 1, "config_yaml": base64.b64encode(f"dataDir: {self.home}".encode()).decode()}).encode()
        req = (ctypes.c_uint8 * len(body)).from_buffer_copy(body); response = Buffer()
        rc = call(b"plugin.register", req, len(body), ctypes.byref(response))
        result = json.loads(ctypes.string_at(response.ptr, response.len)); free(response.ptr, response.len)
        self.assertEqual(rc, 0, result)
        connections = self.home / "helper-connections"
        self.assertTrue(self.wait_until(connections.exists))
        initial_connects = connections.read_text().count("Q2")
        starts = self.home / "helper-starts"
        initial_starts = starts.read_text().count("start")
        (self.home / "quit-independent").touch()
        self.assertTrue(self.wait_until(lambda: connections.read_text().count("Q2") >= initial_connects))
        time.sleep(1.3)
        self.assertEqual(connections.read_text().count("Q2"), initial_connects,
                         "Q2I user quit must pause reconnect attempts")
        self.assertEqual(starts.read_text().count("start"), initial_starts,
                         "an independent helper must never be spawned after user quit")
        same_config = json.dumps({"schema_version": 1, "config_yaml": base64.b64encode(f"dataDir: {self.home}".encode()).decode()}).encode()
        same_req = (ctypes.c_uint8 * len(same_config)).from_buffer_copy(same_config); same_response = Buffer()
        self.assertEqual(call(b"plugin.reconfigure", same_req, len(same_config), ctypes.byref(same_response)), 0)
        free(same_response.ptr, same_response.len)
        time.sleep(.3)
        self.assertEqual(connections.read_text().count("Q2"), initial_connects,
                         "same-config reconfigure must preserve the paused state")
        changed_home = self.base / "independent-changed-home"
        changed_config = json.dumps({"schema_version": 1, "config_yaml": base64.b64encode(f"dataDir: {changed_home}".encode()).decode()}).encode()
        changed_req = (ctypes.c_uint8 * len(changed_config)).from_buffer_copy(changed_config); changed_response = Buffer()
        self.assertEqual(call(b"plugin.reconfigure", changed_req, len(changed_config), ctypes.byref(changed_response)), 0)
        free(changed_response.ptr, changed_response.len)
        self.assertTrue(self.wait_until(lambda: (changed_home / "helper-starts").exists()))
        second_shutdown = Buffer()
        self.assertEqual(call(b"plugin.shutdown", None, 0, ctypes.byref(second_shutdown)), 0)
        free(second_shutdown.ptr, second_shutdown.len)
        self.assertEqual(call(b"plugin.quiesce", None, 0, ctypes.byref(Buffer())), 0)
        self.assertTrue(self.socket_exists(), "quiescing a connector must leave the independent owner running")
        self.assertEqual(self.rpc("plugin.quiesce")[0], 0)

    def test_rejects_bad_config_unsafe_directory_and_bad_payload_digest(self):
        link = self.base / "symlink-data"
        link.symlink_to(self.base, target_is_directory=True)
        rc, response = self.register(dataDir=link)
        self.assertNotEqual(rc, 0)
        self.assertIn("error", response)
        rc, response = self.rpc("plugin.register", {"schema_version": 7})
        self.assertNotEqual(rc, 0)
        self.assertIn("schema_version", response["error"]["message"])
        unknown_yaml = base64.b64encode(b"enabled: true\nfuturePluginOption: true\n").decode()
        rc, response = self.rpc("plugin.register", {"schema_version": 1, "config_yaml": unknown_yaml})
        self.assertNotEqual(rc, 0)
        self.assertIn("Unknown plugin config field", response["error"]["message"])
        bad_library = self.compile_plugin(self.zip_path, self.build_root / "bad.dylib", digest="0" * 64)
        bad = ctypes.CDLL(str(bad_library)); api = PluginAPI()
        bad.cliproxy_plugin_init(ctypes.byref(HostAPI(1, None, None, None)), ctypes.byref(api))
        call = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                ctypes.POINTER(Buffer))(api.call)
        free = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_size_t)(api.free_buffer)
        body = json.dumps({"schema_version": 1, "config_yaml": base64.b64encode(f"dataDir: {self.base / 'bad-home'}".encode()).decode()}).encode()
        req = (ctypes.c_uint8 * len(body)).from_buffer_copy(body); response = Buffer()
        rc = call(b"plugin.register", req, len(body), ctypes.byref(response))
        result = json.loads(ctypes.string_at(response.ptr, response.len)); free(response.ptr, response.len)
        self.assertNotEqual(rc, 0)
        self.assertIn("SHA-256", result["error"]["message"])


def sys_platform():
    import sys
    return sys.platform


if __name__ == "__main__":
    unittest.main()
