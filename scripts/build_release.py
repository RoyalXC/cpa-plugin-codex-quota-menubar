#!/usr/bin/env python3
"""Build a CPA store archive; Python is a build dependency, never a user runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "codex-quota-menubar"
APP_NAME = "Codex Quota Menubar.app"
BUNDLE_ID = "com.royalxc.codex-quota-menubar"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def app_tree_sha256(app):
    """Canonical relative paths, modes and contents, shared with the native verifier."""
    digest = hashlib.sha256()
    def visit(directory):
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            name = path.relative_to(app).as_posix().encode()
            digest.update(struct.pack('<Q', len(name)) + name + struct.pack('<I', path.lstat().st_mode & 0o7777))
            if path.is_symlink():
                contents = os.readlink(path).encode()
                digest.update(b'l' + struct.pack('<Q', len(contents)) + contents)
            elif path.is_dir():
                digest.update(b'd')
                visit(path)
            elif path.is_file():
                contents = path.read_bytes()
                digest.update(b'f' + struct.pack('<Q', len(contents)) + contents)
            else:
                raise ValueError('Unsupported application tree entry')
    visit(app)
    return digest.hexdigest()


def build(arch, output, minimum="13.0", identity="-", notary_profile=None):
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("VERSION must contain a dotted numeric version")
    if arch not in {"arm64", "amd64"}:
        raise ValueError("Unsupported architecture")
    compiler_arch = "x86_64" if arch == "amd64" else "arm64"
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    sdk_version = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="cpa-quota-build-") as temporary:
        staging = Path(temporary)
        app = staging / APP_NAME
        executable = app / "Contents/MacOS/QuotaMenubar"
        executable.parent.mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        shutil.copy2(ROOT / "menubar/assets/QuotaMenubar.icns", resources / "QuotaMenubar.icns")
        main = staging / "main.swift"
        shutil.copy2(ROOT / "menubar/native/QuotaMenubar.swift", main)
        command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-sdk", sdk,
                   "-target", f"{compiler_arch}-apple-macos{minimum}", "-framework", "AppKit", "-lsqlite3"]
        if int(sdk_version.split(".")[0]) >= 27:
            command += ["-D", "QUOTA_MACOS27_SDK"]
        command += [str(main), str(ROOT / "menubar/native/QuotaEngine.swift"),
                    str(ROOT / "menubar/native/QuotaIPC.swift"), "-o", str(executable)]
        run(*command)
        info = {"CFBundleExecutable": "QuotaMenubar", "CFBundleIdentifier": BUNDLE_ID,
                "CFBundleName": "Codex Quota Menubar", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version, "CFBundleVersion": version,
                "CFBundleIconFile": "QuotaMenubar.icns", "LSUIElement": True,
                "LSMinimumSystemVersion": minimum, "NSHighResolutionCapable": True,
                "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        signing = ["codesign", "--force", "--sign", identity]
        if identity != "-":
            signing += ["--options", "runtime", "--timestamp"]
        run(*signing, str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        payload = staging / "helper.zip"
        run("ditto", "-c", "-k", "--keepParent", str(app), str(payload))
        if notary_profile:
            if identity == "-":
                raise ValueError("Notarization requires a Developer ID identity")
            run("xcrun", "notarytool", "submit", str(payload), "--keychain-profile", notary_profile, "--wait")
            run("xcrun", "stapler", "staple", str(app))
            payload.unlink()
            run("ditto", "-c", "-k", "--keepParent", str(app), str(payload))
        header = staging / "QuotaPayload.h"
        data = payload.read_bytes()
        # Keep generated build inputs out of the published source repository.
        with header.open("w") as stream:
            stream.write("#include <stddef.h>\n")
            stream.write(f'#define QUOTA_VERSION "{version}"\n')
            stream.write(f'#define QUOTA_PAYLOAD_SHA256 "{sha256(payload)}"\n')
            stream.write(f'#define QUOTA_APP_TREE_SHA256 "{app_tree_sha256(app)}"\n')
            stream.write(f'#define QUOTA_PAYLOAD_ARCH "{arch}"\n')
            stream.write("static const unsigned char quota_payload_bytes[] = {\n")
            for start in range(0, len(data), 24):
                stream.write(",".join(f"0x{value:02x}" for value in data[start:start + 24]) + ",\n")
            stream.write("};\nstatic const size_t quota_payload_size = sizeof(quota_payload_bytes);\n")
        library = staging / f"{PLUGIN_ID}.dylib"
        run("xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-O2", "-arch", compiler_arch,
            "-isysroot", sdk, f"-mmacosx-version-min={minimum}", "-framework", "Foundation",
            "-Werror", "-Wall", "-Wextra", "-Wno-unused-parameter", "-I", str(staging),
            str(ROOT / "plugin/QuotaPlugin.m"), "-o", str(library))
        run(*signing, str(library))
        run("codesign", "--verify", "--strict", str(library))
        archive = output / f"{PLUGIN_ID}_{version}_darwin_{arch}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
            package.write(library, library.name)
        (output / f"build-{arch}.json").write_text(json.dumps({
            "version": version, "arch": arch, "minimumMacOS": minimum, "sdk": sdk_version,
            "signing": "ad-hoc" if identity == "-" else "developer-id",
            "helperNotarized": bool(notary_profile), "pluginNotarized": False,
            "archive": archive.name, "sha256": sha256(archive),
        }, indent=2) + "\n")
        # Retain the signed helper only under ignored build/, for self-test and preview.
        development = ROOT / "build" / arch
        development.mkdir(parents=True, exist_ok=True)
        helper_copy = development / APP_NAME
        if helper_copy.exists():
            shutil.rmtree(helper_copy)
        shutil.copytree(app, helper_copy)
    write_checksums(output)
    print(archive)
    return archive


def write_checksums(output):
    output = Path(output)
    archives = sorted(output.glob(f"{PLUGIN_ID}_*_darwin_*.zip"))
    (output / "checksums.txt").write_text("".join(f"{sha256(archive)}  {archive.name}\n" for archive in archives))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", choices=["arm64", "amd64"], required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--minimum-macos", default="13.0")
    parser.add_argument("--identity", default=os.environ.get("QUOTA_SIGN_IDENTITY", "-"))
    parser.add_argument("--notary-profile", default=os.environ.get("QUOTA_NOTARY_PROFILE"))
    args = parser.parse_args()
    build(args.arch, args.output, args.minimum_macos, args.identity, args.notary_profile)


if __name__ == "__main__":
    main()
