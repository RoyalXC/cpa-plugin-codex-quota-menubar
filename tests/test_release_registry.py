"""Protect release/source publication against stale tags and corrupt packages."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from update_registry import update


class ReleaseRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.output = self.directory / 'registry.json'

    def release(self, version):
        directory = self.directory / version
        directory.mkdir()
        for arch, cpu in [('arm64', 0x0100000c), ('amd64', 0x01000007)]:
            package = directory / f'codex-quota-menubar_{version}_darwin_{arch}.zip'
            with zipfile.ZipFile(package, 'w') as archive:
                archive.writestr('codex-quota-menubar.dylib', struct.pack('<IIII', 0xfeedfacf, cpu, 0, 6) + bytes(100_000))
            metadata = {'version': version, 'arch': arch, 'signing': 'test', 'sdk': 'test',
                        'sha256': hashlib.sha256(package.read_bytes()).hexdigest()}
            (directory / f'build-{arch}.json').write_text(json.dumps(metadata))
        return directory

    def test_tag_version_does_not_depend_on_main_version(self):
        release = self.release('9.2.1')
        self.assertTrue(update(release, self.output, '9.2.1'))
        plugin = json.loads(self.output.read_text())['plugins'][0]
        self.assertEqual(plugin['version'], '9.2.1')
        self.assertEqual(len(plugin['install']['artifacts']), 2)
        self.assertTrue(all('/v9.2.1/' in artifact['url'] for artifact in plugin['install']['artifacts']))

    def test_old_tag_preserves_newer_source(self):
        update(self.release('1.10.0'), self.output, '1.10.0')
        before = self.output.read_bytes()
        self.assertFalse(update(self.release('1.9.0'), self.output, '1.9.0'))
        self.assertEqual(self.output.read_bytes(), before)

    def test_retains_previous_version_artifacts(self):
        update(self.release('1.0.0'), self.output, '1.0.0')
        previous = json.loads(self.output.read_text())['plugins'][0]['install']
        update(self.release('1.1.0'), self.output, '1.1.0')
        versions = json.loads(self.output.read_text())['plugins'][0]['versions']
        self.assertEqual([item['version'] for item in versions], ['1.1.0', '1.0.0'])
        self.assertEqual(versions[1]['install'], previous)

    def test_corrupt_release_does_not_modify_source(self):
        update(self.release('1.0.0'), self.output, '1.0.0')
        before = self.output.read_bytes()
        release = self.release('1.1.0')
        metadata = json.loads((release / 'build-arm64.json').read_text())
        metadata['sha256'] = '0' * 64
        (release / 'build-arm64.json').write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, 'hash'):
            update(release, self.output, '1.1.0')
        self.assertEqual(self.output.read_bytes(), before)

    def test_version_cannot_be_used_as_a_path(self):
        with self.assertRaisesRegex(ValueError, 'numeric'):
            update(self.directory, self.output, '../1.0.0')
        self.assertFalse(self.output.exists())
