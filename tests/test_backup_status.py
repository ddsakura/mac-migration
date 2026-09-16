"""Exercise the full backup script with isolated HOME and fake external tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

BACKUP = Path(__file__).resolve().parents[1] / 'backup.sh'


class BackupStatusTests(unittest.TestCase):
    def run_backup(self, encryption_status=0, brew_status=0, encrypt=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home = root / 'home'
            home.mkdir()
            (home / '.zshrc').write_text('# fixture\n')
            config = home / '.config'
            (config / 'gh').mkdir(parents=True)
            (config / 'starship.toml').write_text('add_newline = false\n')
            (config / '.hidden').write_text('hidden fixture\n')
            (config / 'gh/config.yml').write_text('git_protocol: ssh\n')
            (config / 'linked.toml').symlink_to('starship.toml')
            scripts = root / 'scripts'
            scripts.mkdir()
            shutil.copy2(BACKUP, scripts / 'backup.sh')
            (scripts / 'encrypt-backup.sh').write_text(f'exit {encryption_status}\n')
            binaries = root / 'bin'
            binaries.mkdir()
            for tool in ('brew', 'defaults', 'sw_vers', 'xcodebuild', 'node', 'npm',
                         'ruby', 'python3', 'java', 'go', 'rustc', 'swift'):
                stub = binaries / tool
                stub.write_text(f'#!/bin/sh\nexit {brew_status if tool == "brew" else 0}\n')
                stub.chmod(0o700)
            result = subprocess.run(
                ['/bin/bash', str(scripts / 'backup.sh')], cwd=root,
                env={**os.environ, 'HOME': str(home), 'PATH': f'{binaries}:/usr/bin:/bin'},
                # First read consumes one character; the second consumes a line.
                input='ny\n' if encrypt else 'nn\n', text=True, capture_output=True,
                timeout=20,
            )
            if brew_status == 0:
                self.assertEqual((root / 'mac-migration/dotfiles/.zshrc').read_text(), '# fixture\n')
                self.assertTrue((root / 'mac-migration/versions.txt').exists())
                saved = root / 'mac-migration/dotfiles/.config'
                for item in ('starship.toml', '.hidden', 'gh/config.yml'):
                    self.assertEqual((saved / item).read_text(), (config / item).read_text())
                self.assertTrue((saved / 'linked.toml').is_symlink())
                self.assertFalse((root / 'mac-migration/dotfiles/gh').exists())
            return result

    def test_encryption_failure_is_distinct(self):
        result = self.run_backup(encryption_status=1)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('備份已完成，但加密未完成', result.stdout)

    def test_backup_failure_is_normalized(self):
        result = self.run_backup(brew_status=2)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_encryption_success(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_skipped_encryption_is_success(self):
        result = self.run_backup(encryption_status=1, encrypt=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
