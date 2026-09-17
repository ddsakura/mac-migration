"""App inventory uses only synthetic bundles, never the real Applications folders."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest

COMMON = Path(__file__).resolve().parents[1] / 'migration-common.sh'


class InstalledAppsTests(unittest.TestCase):
    def test_failed_scan_keeps_partial_entries_and_scans_next_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first, second = root / 'first', root / 'second'
            for folder, name in ((first, 'First'), (second, 'Second')):
                contents = folder / (name + '.app') / 'Contents'
                contents.mkdir(parents=True)
                (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleName': name}))
            binaries = root / 'bin'
            binaries.mkdir()
            stub = binaries / 'find'
            stub.write_text('#!/bin/sh\n/usr/bin/find "$@"\ncase "$2" in */first) exit 1;; esac\n')
            stub.chmod(0o700)
            result = subprocess.run(['/bin/bash', '-c',
                                     'set -e; source "$1"; if list_installed_apps "$2" "$3"; then exit 0; else exit 1; fi',
                                     'fixture', str(COMMON), str(first), str(second)],
                                    env={**os.environ, 'PATH': f'{binaries}:/usr/bin:/bin'},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('# WARNING: scan incomplete', result.stdout)
            self.assertIn('First\tunknown\t', result.stdout)
            self.assertIn('Second\tunknown\t', result.stdout)

    def test_inventory_nested_bundles_fallbacks_and_special_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            system = root / 'Applications'
            user = root / 'home/Applications'
            def bundle(path, metadata):
                (path / 'Contents').mkdir(parents=True)
                (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
            bundle(system / 'Example.app', {'CFBundleDisplayName': 'Example',
                                           'CFBundleShortVersionString': '1.2'})
            bundle(system / 'Example.app/Contents/Helper.app', {'CFBundleName': 'HiddenHelper'})
            bundle(system / 'Utilities/Tool.app', {'CFBundleName': 'Tool', 'CFBundleVersion': '42'})
            (user / 'Missing Metadata.app').mkdir(parents=True)
            bundle(user / 'Special.app', {'CFBundleName': 'Name\nWith\tTabs',
                                         'CFBundleShortVersionString': '3'})
            result = subprocess.run(['/bin/bash', '-c',
                                     'source "$1"; shift; list_installed_apps "$@"',
                                     'fixture', str(COMMON), str(system), str(user), str(root / 'absent')],
                                    capture_output=True, text=True, check=True)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 7)  # Three header lines, four apps.
            self.assertIn('Example\t1.2\t', result.stdout)
            self.assertIn('Tool\t42\t', result.stdout)
            self.assertIn('Missing\\ Metadata\tunknown\t', result.stdout)
            self.assertIn("$'Name\\nWith\\tTabs'\t3\t", result.stdout)
            self.assertNotIn('HiddenHelper', result.stdout)

    def test_missing_roots_produce_header_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['/bin/bash', '-c',
                                     'source "$1"; list_installed_apps "$2"',
                                     'fixture', str(COMMON), str(Path(tmp) / 'absent')],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(len(result.stdout.splitlines()), 3)
