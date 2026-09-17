"""Round-trip extra settings using fake HOME only."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ExtraSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.backup = self.root / 'backup'
        self.backup.mkdir()
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': '/usr/bin:/bin'}

    def run_shell(self, code):
        return subprocess.run(['/bin/bash', '-c',
                               'set -e; umask 077; source "$1/migration-common.sh"; ' + code,
                               'fixture', str(REPO), str(self.backup)],
                              env=self.env, text=True, capture_output=True)

    def put(self, name, text='original'):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o600)
        return path

    def restore(self, mode='yes'):
        return self.run_shell('confirm() { [ "' + mode + '" != no ]; }; '
                              'run_or_dry() { shift; ' +
                              ('return 0;' if mode == 'dry' else '"$@";') +
                              ' }; restore_extra_settings "$2"')

    def test_all_paths_roundtrip_permissions_and_original_preservation(self):
        names = ['.profile', '.zlogin', '.zlogout', '.netrc', '.pypirc',
                 '.aws/credentials', '.azure/config', '.kube/config', '.gnupg/private-key',
                 '.docker/config.json', '.docker/contexts/meta/context', 'bin/custom', '.local/bin/custom']
        for name in names:
            self.put(name)
        self.put('.docker/ignored-volume')
        link = self.home / 'bin/external'
        link.symlink_to('/not-collected/external')
        result = self.run_shell('backup_extra_settings "$2"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.backup / 'extra-settings').iterdir())), 13)
        self.assertFalse((self.backup / 'extra-settings/docker-config/ignored-volume').exists())
        for name in names:
            (self.home / name).write_text('new-machine')
        for mode in ('no', 'dry'):
            result = self.restore(mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.home / '.netrc').read_text(), 'new-machine')
            self.assertFalse(list(self.home.glob('*.before-restore-*')))
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in names:
            self.assertEqual((self.home / name).read_text(), 'original')
            self.assertEqual((self.home / name).stat().st_mode & 0o777, 0o600)
        old, = self.home.glob('.netrc.before-restore-*')
        self.assertEqual(old.read_text(), 'new-machine')
        self.assertEqual(os.readlink(link), '/not-collected/external')

    def test_missing_sources_and_legacy_backup_skip(self):
        self.assertEqual(self.run_shell('backup_extra_settings "$2"').returncode, 0)
        self.assertFalse((self.backup / 'extra-settings').exists())
        self.assertEqual(self.restore().returncode, 0)

    def test_failed_items_continue_and_partial_data_is_not_restored(self):
        self.put('.netrc', 'keep-netrc')
        self.put('.aws/credentials', 'keep-aws')
        self.put('bin/custom', 'saved-script')
        result = self.run_shell(
            'cp() { printf partial > "${@: -1}"; return 1; }; '
            'rsync() { case "${@: -1}" in */aws/) printf partial > "${@: -1}/credentials"; return 1;; '
            '*) /usr/bin/rsync "$@";; esac; }; '
            'if backup_extra_settings "$2"; then exit 0; else exit 1; fi')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.backup / 'extra-settings-failed.txt').read_text(), 'netrc\naws\n')
        self.assertEqual((self.backup / 'extra-settings/bin/custom').read_text(), 'saved-script')
        (self.home / 'bin/custom').unlink()
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / '.netrc').read_text(), 'keep-netrc')
        self.assertEqual((self.home / '.aws/credentials').read_text(), 'keep-aws')
        self.assertEqual((self.home / 'bin/custom').read_text(), 'saved-script')
        self.assertIn('略過不完整', result.stderr)

    def test_socket_excluded_root_symlink_skipped_and_overlap_rejected(self):
        directory = self.home / '.gnupg'
        directory.mkdir()
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(directory / 'S.gpg-agent'))
        outside = self.root / 'outside'
        outside.mkdir()
        (self.home / '.aws').symlink_to(outside)
        result = self.run_shell('backup_extra_settings "$2"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.backup / 'extra-settings/gnupg/S.gpg-agent').exists())
        self.assertFalse((self.backup / 'extra-settings/aws').exists())
        self.assertIn('略過符號連結', result.stderr)
        result = self.run_shell('integrity backup-preflight "$HOME/.gnupg/output" "${EXTRA_PATHS[@]}"')
        self.assertNotEqual(result.returncode, 0)

    def test_copy_failure_keeps_existing_destination(self):
        self.put('.aws/credentials')
        self.assertEqual(self.run_shell('backup_extra_settings "$2"').returncode, 0)
        (self.home / '.aws/credentials').write_text('keep')
        result = self.run_shell('rsync() { return 1; }; confirm() { return 0; }; '
                                'run_or_dry() { shift; "$@"; }; restore_extra_settings "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / '.aws/credentials').read_text(), 'keep')
