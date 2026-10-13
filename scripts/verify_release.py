#!/usr/bin/env python3
"""Validate the exact single-library package contract used by the CPA store."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zipfile


def verify(directory, complete=False, version=None):
    directory = Path(directory)
    packages = sorted(directory.glob('*.zip'))
    if not packages:
        raise ValueError('No release archives')
    version = version or (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Release version must contain three numeric components')
    expected = {f'codex-quota-menubar_{version}_darwin_{arch}.zip' for arch in ('arm64', 'amd64')}
    if complete and {package.name for package in packages} != expected:
        raise ValueError('Release requires exactly the current arm64 and amd64 packages')
    for package in packages:
        match = re.fullmatch(r'codex-quota-menubar_(\d+\.\d+\.\d+)_darwin_(arm64|amd64)\.zip', package.name)
        if not match:
            raise ValueError(f'Invalid CPA asset name: {package.name}')
        with zipfile.ZipFile(package) as archive:
            if archive.namelist() != ['codex-quota-menubar.dylib']:
                raise ValueError('Archive must contain exactly the root plugin library')
            data = archive.read('codex-quota-menubar.dylib')
            if len(data) < 100_000:
                raise ValueError('Plugin is too small to contain the native helper payload')
            magic, cpu, subtype, kind = struct.unpack_from('<IIII', data)
            expected_cpu = 0x0100000c if match[2] == 'arm64' else 0x01000007
            if magic != 0xfeedfacf or cpu != expected_cpu or kind != 6:
                raise ValueError('Package must contain a matching 64-bit Mach-O dynamic library')
        if match[1] != version:
            raise ValueError('Package version does not match VERSION')
        metadata = json.loads((directory / f'build-{match[2]}.json').read_text())
        if metadata['version'] != match[1] or metadata['arch'] != match[2]:
            raise ValueError('Package/build metadata mismatch')
        if metadata['sha256'] != hashlib.sha256(package.read_bytes()).hexdigest():
            raise ValueError('Package hash/build metadata mismatch')
        print(f'OK {package.name} ({metadata["signing"]}, SDK {metadata["sdk"]})')
    checksum_file = directory / 'checksums.txt'
    if checksum_file.exists():
        checksums = {}
        for line in checksum_file.read_text().splitlines():
            digest, name = line.split('  ', 1)
            if name in checksums:
                raise ValueError('Duplicate checksum entry')
            checksums[name] = digest
        actual = {package.name: hashlib.sha256(package.read_bytes()).hexdigest() for package in packages}
        if checksums != actual:
            raise ValueError('checksums.txt does not match all release archives')


if __name__ == '__main__':
    verify(sys.argv[1] if len(sys.argv) > 1 else 'dist', '--complete' in sys.argv)
