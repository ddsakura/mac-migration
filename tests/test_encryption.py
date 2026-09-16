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

    def test_delete_only_current_backup(self):
        previous = self.root / 'mac-migration-previous'
        previous.mkdir()
        code, output = self.run_encryption(delete='y')
        self.assertEqual(code, 0, output)
        self.assertFalse(self.source.exists())
        self.assertTrue(previous.exists())
        self.assertEqual(len(list(self.root.glob('*.dmg'))), 1)

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
        fake.write_text('#!/bin/sh\nexit 2\n')
        fake.chmod(0o700)
        with patch.dict(os.environ, {'PATH': str(fake_bin) + ':' + os.environ['PATH']}):
            code, output = interact(self.source, [('設定備份密碼:', PASSWORD)])
        self.assertNotEqual(code, 0, output)
        self.assertTrue(self.source.exists())
        self.assertFalse(list(self.root.glob('*.dmg')))
        self.assertFalse(list(self.root.glob('.mac-migration-encrypt.*')))


if __name__ == '__main__':
    unittest.main()
