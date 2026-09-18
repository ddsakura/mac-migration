"""Integration tests with macOS hdiutil and a controlling terminal.
Run: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'encrypt-backup.sh'
HDIUTIL = shutil.which('hdiutil')
PASSWORD = ' test-only 密碼 $S3cret! '


def interact(source, replies):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp('bash', ['bash', str(SCRIPT), str(source)])
    output = b''
    pending = list(replies)
    cursor = 0
    deadline = time.monotonic() + 90
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                output += data
                if pending:
                    marker, reply = pending[0]
                    found = output.find(marker.encode(), cursor)
                    if found >= 0:
                        cursor = found + len(marker.encode())
                        pending.pop(0)
                        # Allow the native password prompt to disable terminal echo.
                        time.sleep(0.1)
                        os.write(fd, (reply + '\n').encode())
        else:
            raise AssertionError('Interactive command timed out: ' + output.decode(errors='replace'))
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')
    finally:
        os.close(fd)
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except ProcessLookupError:
            pass


@unittest.skipUnless(HDIUTIL, 'Requires macOS hdiutil')
class EncryptionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='migration test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'mac-migration'
        for name in ('dotfiles', 'ssh', 'defaults'):
            (self.source / name).mkdir(parents=True)
        (self.source / 'dotfiles' / '.sample').write_text('sample config\n')

    def run_encryption(self, password=PASSWORD, verify=PASSWORD, delete='n'):
        return interact(self.source, [
            ('設定備份密碼:', password),
            ('驗證備份密碼:', verify),
            ('[y/N]', delete),
        ])

    def test_round_trip_and_keep_plaintext(self):
        code, output = self.run_encryption()
        self.assertEqual(code, 0, output)
        self.assertNotIn(PASSWORD, output)
        self.assertTrue(self.source.exists())
        archive, = self.root.glob('*.dmg')
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        denied = subprocess.run([HDIUTIL, 'verify', str(archive), '-stdinpass', '-nocache'],
                                input=b'wrong\0', capture_output=True)
        self.assertNotEqual(denied.returncode, 0)
        encrypted = subprocess.run([HDIUTIL, 'isencrypted', str(archive)], capture_output=True)
        self.assertIn(b'encrypted: YES', encrypted.stdout)
        dest = self.root / 'mounted'
        dest.mkdir()
        result = subprocess.run([HDIUTIL, 'attach', str(archive), '-stdinpass', '-readonly',
                                 '-nobrowse', '-mountpoint', str(dest)],
                                input=(PASSWORD + '\0').encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            self.assertEqual((dest / 'dotfiles/.sample').read_text(), 'sample config\n')
        finally:
            subprocess.run([HDIUTIL, 'detach', str(dest)], check=True, capture_output=True)
        self.assertFalse(list(self.root.glob('.mac-migration-encrypt.*')))

    def test_dmg_preserves_integrity_manifest_and_special_names(self):
        (self.source / 'dotfiles' / 'café 👩🏽\n.hidden').write_text('unicode fixture')
        (self.source / 'dotfiles/link').symlink_to('missing\nexternal')
        (self.source / 'backup-format').write_text('mac-migration-v1\n')
        helper = SCRIPT.parent / 'migration-integrity.pl'
        subprocess.run(['/usr/bin/perl', str(helper), 'create', str(self.source)],
                       check=True, capture_output=True)
        code, output = self.run_encryption()
        self.assertEqual(code, 0, output)
        archive, = self.root.glob('*.dmg')
        dest = self.root / 'mounted'
        dest.mkdir()
        result = subprocess.run([HDIUTIL, 'attach', str(archive), '-stdinpass', '-readonly',
                                 '-nobrowse', '-mountpoint', str(dest)],
                                input=(PASSWORD + '\0').encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            checked = subprocess.run(['/usr/bin/perl', str(helper), 'verify', str(dest)],
                                     capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr + repr(
                [str(p.relative_to(dest)) for p in dest.rglob('*')]))
        finally:
            subprocess.run([HDIUTIL, 'detach', str(dest)], check=True, capture_output=True)

    def test_delete_only_current_backup(self):
        previous = self.root / 'mac-migration-previous'
        previous.mkdir()
        code, output = self.run_encryption(delete='y')
        self.assertEqual(code, 0, output)
        self.assertFalse(self.source.exists())
        self.assertTrue(previous.exists())
        self.assertEqual(len(list(self.root.glob('*.dmg'))), 1)

    def test_diskutil_rejects_case_collisions_on_sensitive_source(self):
        image = self.root / 'case-source.sparsebundle'
        subprocess.run([HDIUTIL, 'create', '-size', '128m', '-type', 'SPARSEBUNDLE',
                        '-fs', 'Case-sensitive APFS', '-volname', 'case-fixture', str(image)],
                       check=True, capture_output=True, timeout=30)
        mount = self.root / 'case-mount'
        mount.mkdir()
        subprocess.run([HDIUTIL, 'attach', str(image), '-nobrowse', '-mountpoint', str(mount)],
                       check=True, capture_output=True, timeout=30)
        try:
            source = mount / 'mac-migration'
            for name in ('dotfiles', 'ssh', 'defaults'):
                (source / name).mkdir(parents=True)
            (source / 'dotfiles/File.txt').write_text('upper')
            (source / 'dotfiles/file.txt').write_text('lower')
            fake_bin = self.root / 'bin'
            fake_bin.mkdir()
            stub = fake_bin / 'diskutil'
            stub.write_text('#!/bin/sh\ncase "$*" in *--help) exit 0;; esac\necho unexpected-create\nexit 2\n')
            stub.chmod(0o700)
            with patch.dict(os.environ, {'PATH': str(fake_bin) + ':' + os.environ['PATH']}):
                code, output = interact(source, [])
            self.assertNotEqual(code, 0, output)
            self.assertIn('檔名衝突', output)
            self.assertNotIn('unexpected-create', output)
            self.assertNotIn('設定備份密碼:', output)
            self.assertEqual((source / 'dotfiles/File.txt').read_text(), 'upper')
            self.assertEqual((source / 'dotfiles/file.txt').read_text(), 'lower')
            self.assertFalse(list(mount.glob('*.dmg')))
            self.assertFalse(list(mount.glob('.mac-migration-encrypt.*')))
        finally:
            subprocess.run([HDIUTIL, 'detach', str(mount)], check=True, capture_output=True, timeout=30)

    def test_wrong_verification_keeps_source(self):
        code, output = self.run_encryption(verify='wrong')
        self.assertNotEqual(code, 0, output)
        self.assertIn('解密驗證失敗', output)
        self.assertTrue(self.source.exists())
        self.assertFalse(list(self.root.glob('*.dmg')))
        self.assertFalse(list(self.root.glob('.mac-migration-encrypt.*')))

    def test_empty_password_rejected(self):
        code, output = self.run_encryption(password='')
        self.assertNotEqual(code, 0, output)
        self.assertIn('密碼不可為空', output)
        self.assertTrue(self.source.exists())
        self.assertFalse(list(self.root.glob('*.dmg')))

    def test_noninteractive_rejected(self):
        result = subprocess.run(['bash', str(SCRIPT), str(self.source)], input='', text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.source.exists())

    def test_archiver_failure_keeps_source_and_cleans_temp(self):
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        fake = fake_bin / 'hdiutil'
        fake.write_text('#!/bin/sh\necho unexpected-hdiutil-call\nexit 2\n')
        fake.chmod(0o700)
        diskutil = fake_bin / 'diskutil'
        diskutil.write_text('#!/bin/sh\ncase "$*" in *--help) exit 0;; esac\nexit 2\n')
        diskutil.chmod(0o700)
        with patch.dict(os.environ, {'PATH': str(fake_bin) + ':' + os.environ['PATH']}):
            code, output = interact(self.source, [('設定備份密碼:', PASSWORD)])
        self.assertNotEqual(code, 0, output)
        self.assertIn('使用 diskutil image create', output)
        self.assertNotIn('unexpected-hdiutil-call', output)
        self.assertTrue(self.source.exists())
        self.assertFalse(list(self.root.glob('*.dmg')))
        self.assertFalse(list(self.root.glob('.mac-migration-encrypt.*')))

    def test_unsupported_diskutil_uses_legacy_creation(self):
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        diskutil = fake_bin / 'diskutil'
        diskutil.write_text('#!/bin/sh\nexit 1\n')
        diskutil.chmod(0o700)
        with patch.dict(os.environ, {'PATH': str(fake_bin) + ':' + os.environ['PATH']}):
            code, output = self.run_encryption()
        self.assertEqual(code, 0, output)
        self.assertIn('hdiutil 相容模式', output)
        archive, = self.root.glob('*.dmg')
        verified = subprocess.run([HDIUTIL, 'verify', str(archive), '-stdinpass', '-nocache'],
                                  input=(PASSWORD + '\0').encode(), capture_output=True, timeout=30)
        self.assertEqual(verified.returncode, 0, verified.stderr)


if __name__ == '__main__':
    unittest.main()
