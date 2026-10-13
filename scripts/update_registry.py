#!/usr/bin/env python3
"""Pin the additional CPA source to verified release URLs without GitHub API lookup."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from verify_release import verify

ROOT = Path(__file__).resolve().parents[1]


def version_tuple(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Release version must contain three numeric components')
    return tuple(int(part) for part in version.split('.'))


def update(directory, output, version=None):
    directory = Path(directory)
    output = Path(output)
    version = version or (ROOT / 'VERSION').read_text().strip()
    release_version = version_tuple(version)
    plugin = json.loads((ROOT / 'store-entry.json').read_text())['plugins'][0]
    previous = None
    if output.exists():
        previous = next((entry for entry in json.loads(output.read_text())['plugins']
                         if entry['id'] == plugin['id']), None)
    if previous and previous.get('version') and version_tuple(previous['version']) > release_version:
        print(f"Keeping newer source version {previous['version']}; release {version} will not downgrade it")
        return False
    verify(directory, complete=True, version=version)
    plugin['version'] = version
    plugin['install'] = {'type': 'direct', 'artifacts': []}
    for arch in ('arm64', 'amd64'):
        archive = directory / f"{plugin['id']}_{version}_darwin_{arch}.zip"
        data = archive.read_bytes()
        plugin['install']['artifacts'].append({
            'goos': 'darwin', 'goarch': arch,
            'url': f"{plugin['repository']}/releases/download/v{version}/{archive.name}",
            'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data),
        })
    history = {}
    if previous and previous.get('install', {}).get('type') == 'direct':
        for entry in previous.get('versions', []):
            history[entry['version']] = entry
        history[previous['version']] = {'version': previous['version'], 'install': previous['install']}
    history[version] = {'version': version, 'install': plugin['install']}
    plugin['versions'] = sorted(history.values(), key=lambda entry: version_tuple(entry['version']), reverse=True)
    output.write_text(json.dumps({'schema_version': 2, 'plugins': [plugin]}, indent=2) + '\n')
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'registry.json')
    parser.add_argument('--version', help='Released version, independent of the main branch VERSION')
    args = parser.parse_args()
    update(args.directory, args.output, args.version)
