"""Restore config fixtures into an isolated HOME; stub installation tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RESTORE = Path(__file__).resolve().parents[1] / 'restore.sh'


class ConfigRestoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='config restore ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        (self.home / '.config/gh').mkdir(parents=True)
        (self.home / '.nvm').mkdir()
        (self.home / '.config/starship.toml').write_text('old\n')
        (self.home / '.config/local-only').write_text('keep\n')
        (self.home / '.config/gh/config.yml').write_text('old gh\n')
        self.migration = self.root / 'mac-migration'
        (self.migration / 'dotfiles').mkdir(parents=True)
        (self.migration / 'ssh').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('brew', 'xcode-select'):
            stub = self.bin / name
            stub.write_text('#!/bin/sh\nexit 0\n')
            stub.chmod(0o700)

    def restore(self, dry=False):
        args = ['/bin/bash', str(RESTORE), '--migration-dir', str(self.migration)]
        if dry:
            args.append('--dry-run')
        result = subprocess.run(args, env={**os.environ, 'HOME': str(self.home),
                                'PATH': f'{self.bin}:/usr/bin:/bin'},
                                input='nnnn', text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def populate(self, legacy=False):
        source = self.migration / 'dotfiles' / ('gh' if legacy else '.config')
        source.mkdir()
        if legacy:
            (source / 'config.yml').write_text('new gh\n')
        else:
            (source / 'gh').mkdir()
            (source / 'gh/config.yml').write_text('new gh\n')
            (source / 'starship.toml').write_text('new starship\n')
            (source / '.hidden').write_text('hidden\n')
        return source

    def test_full_config_merge_and_repeat(self):
        self.populate()
        self.restore()
        self.restore()
        config = self.home / '.config'
        self.assertEqual((config / 'starship.toml').read_text(), 'new starship\n')
        self.assertEqual((config / '.hidden').read_text(), 'hidden\n')
        self.assertEqual((config / 'gh/config.yml').read_text(), 'new gh\n')
        self.assertEqual((config / 'local-only').read_text(), 'keep\n')
        self.assertFalse((config / '.config').exists())
        self.assertFalse((config / 'gh/gh').exists())

    def test_legacy_gh_merges_without_nesting(self):
        self.populate(legacy=True)
        self.restore()
        self.assertEqual((self.home / '.config/gh/config.yml').read_text(), 'new gh\n')
        self.assertEqual((self.home / '.config/starship.toml').read_text(), 'old\n')
        self.assertFalse((self.home / '.config/gh/gh').exists())

    def test_dry_run_leaves_home_unchanged(self):
        self.populate()
        def snapshot():
            return {str(p.relative_to(self.home)): p.read_bytes() if p.is_file() else None
                    for p in self.home.rglob('*')}
        before = snapshot()
        result = self.restore(dry=True)
        self.assertIn('會合併還原', result.stdout)
        self.assertEqual(snapshot(), before)

    def test_missing_config_keeps_destination(self):
        self.restore()
        self.assertEqual((self.home / '.config/starship.toml').read_text(), 'old\n')
        self.assertEqual((self.home / '.config/gh/config.yml').read_text(), 'old gh\n')
