"""Safety/regression cases: only fake homes, command stubs, temporary data."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
INTEGRITY = REPO / 'migration-integrity.pl'


class AISafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ai safety ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.tmp = self.root / 'tmp'
        self.tmp.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.jsonl'
        self.migration = self.root / 'mac-migration'
        self.env = {**os.environ, 'HOME': str(self.home), 'TMPDIR': str(self.tmp),
                    'CODEX_HOME': str(self.home / '.codex'),
                    'CLAUDE_CONFIG_DIR': str(self.home / '.claude'),
                    'PATH': f'{self.bin}:/usr/bin:/bin', 'FIXTURE_LOG': str(self.log)}
        stub = self.bin / 'stub'
        stub.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as f: f.write(json.dumps([name] + args) + '\\n')
if name == 'pgrep':
    count_file = pathlib.Path(os.environ['TMPDIR']) / 'process-count'
    count = int(count_file.read_text()) if count_file.exists() else 0
    count_file.write_text(str(count + 1))
    if os.environ.get('REOPEN_AFTER') and count >= int(os.environ['REOPEN_AFTER']): sys.exit(0)
    if args[-1] == os.environ.get('RUNNING_NAME'): sys.exit(0)
    sys.exit(int(os.environ.get('PGREP_STATUS', '1')))
if name == 'mv':
    src, dst = args[-2:]
    if '/staged/' in src and pathlib.Path(src).name == os.environ.get('FAIL_INSTALL_ID', 'claude-code') and os.environ.get('FAIL_INSTALL'):
        # Simulate cross-volume mv that partially created the destination before failing.
        if os.environ.get('PARTIAL_INSTALL'):
            pathlib.Path(dst).mkdir(parents=True, exist_ok=True)
            (pathlib.Path(dst) / 'partial').write_text('partial')
        sys.exit(1)
    if pathlib.Path(src).name == '.claude' and '.before-restore-' in dst and os.environ.get('FAIL_SAVE'):
        if os.environ.get('PARTIAL_SAVE'):
            pathlib.Path(dst).mkdir()
            (pathlib.Path(dst) / 'partial').write_text('partial-save')
        elif os.environ.get('SAVE_THEN_FAIL'):
            os.rename(src, dst)
        sys.exit(1)
    if '.before-restore-' in src and os.environ.get('FAIL_ROLLBACK'):
        sys.exit(1)
    os.execv('/bin/mv', ['/bin/mv'] + args)
if name == 'rsync':
    if os.environ.get('FAIL_STAGE') and '/staged/claude-code/' in args[-1]: sys.exit(1)
    status = __import__('subprocess').run(['/usr/bin/rsync'] + args).returncode
    if os.environ.get('CORRUPT_STAGE') and '/staged/codex/' in args[-1]:
        (pathlib.Path(args[-1]) / 'extra-corrupt').write_text('changed')
    sys.exit(status)
if name == 'defaults': sys.exit(1)
''')
        stub.chmod(0o700)
        for name in ('pgrep', 'mv', 'rsync', 'brew', 'defaults', 'xcode-select', 'killall',
                     'sw_vers', 'xcodebuild', 'node', 'npm', 'ruby', 'python3', 'java',
                     'go', 'rustc', 'swift'):
            (self.bin / name).symlink_to(stub)

    def file(self, relative, text='fixture'):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def payload(self, entries=None):
        if entries is None:
            entries = {'codex': {'config.toml': 'new-codex'},
                       'claude-code': {'settings.json': 'new-claude'},
                       'codex-documents': {'note.md': 'new-document'}}
        for name in ('dotfiles', 'ssh', 'defaults', 'developer'):
            (self.migration / name).mkdir(parents=True, exist_ok=True)
        for key, files in entries.items():
            for name, content in files.items():
                path = self.migration / 'developer' / key / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
        return self.migration

    def seal(self):
        (self.migration / 'backup-format').write_text('mac-migration-v1\n')
        result = self.integrity('create', self.migration)
        self.assertEqual(result.returncode, 0, result.stderr)

    def integrity(self, *args):
        return subprocess.run(['/usr/bin/perl', str(INTEGRITY), *map(str, args)],
                              capture_output=True, text=True)

    def run_backup(self, cwd=None):
        return subprocess.run(['/bin/bash', str(REPO / 'backup.sh')], cwd=cwd or self.root,
                              env=self.env, input='n\nn\n', capture_output=True, text=True, timeout=30)

    def restore(self, dry=False, answers='y\nn\nn\nn\n'):
        args = ['/bin/bash', str(REPO / 'restore.sh'), '--migration-dir', str(self.migration)]
        if dry: args += ['--dry-run']
        return subprocess.run(args, cwd=self.root, env=self.env, input=answers,
                              capture_output=True, text=True, timeout=30)

    def snapshot(self):
        result = {}
        for path in self.home.rglob('*'):
            key = str(path.relative_to(self.home))
            result[key] = ('link', os.readlink(path)) if path.is_symlink() else (
                ('dir',) if path.is_dir() else ('file', path.read_bytes()))
        return result

    def test_documents_roundtrip_and_custom_paths(self):
        self.env['CODEX_HOME'] = str(self.home / 'custom-codex')
        self.env['CLAUDE_CONFIG_DIR'] = str(self.home / 'custom-claude')
        self.file('custom-codex/config.toml', 'codex')
        self.file('custom-claude/settings.json', 'claude')
        self.file('Documents/Codex/project/file.txt', 'document')
        backup = self.run_backup()
        self.assertEqual(backup.returncode, 0, backup.stdout + backup.stderr)
        self.assertTrue((self.migration / 'developer/codex-documents/project/file.txt').exists())
        for name in ('custom-codex', 'custom-claude', 'Documents'):
            shutil.rmtree(self.home / name)
        (self.home / '.nvm').mkdir()
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / 'Documents/Codex/project/file.txt').read_text(), 'document')
        self.assertEqual((self.home / 'custom-codex/config.toml').read_text(), 'codex')
        self.assertEqual((self.home / 'custom-claude/settings.json').read_text(), 'claude')
        self.assertFalse((self.home / '.codex').exists())

    def test_missing_sources_are_skipped(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.migration / 'developer/codex-documents').exists())
        self.assertNotIn('pgrep', self.log.read_text())
        self.assertEqual(self.integrity('verify', self.migration).returncode, 0)

    def test_backup_preflight_blocks_active_or_failed_process_query_before_rotation(self):
        self.file('.codex/config.toml')
        self.migration.mkdir()
        keep = self.migration / 'keep'
        keep.write_text('previous')
        for status in ('0', '2', '3', '127'):
            with self.subTest(status=status):
                self.env['PGREP_STATUS'] = status
                result = self.run_backup()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('程序', result.stderr)
                self.assertEqual(keep.read_text(), 'previous')
                self.assertEqual(list(self.migration.iterdir()), [keep])
                self.assertFalse(list(self.root.glob('mac-migration-*')))

    def test_exact_claude_process_names(self):
        self.file('.claude/settings.json')
        self.env['RUNNING_NAME'] = 'claude'
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertIn(['pgrep', '-x', 'Claude'], calls)
        self.assertIn(['pgrep', '-x', 'claude'], calls)
        self.assertFalse(self.migration.exists())

    def test_restore_checks_processes_before_any_home_changes(self):
        self.payload()
        self.seal()
        before = self.snapshot()
        for status in ('0', '2'):
            with self.subTest(status=status):
                self.env['PGREP_STATUS'] = status
                result = self.restore()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))

    def test_manifest_special_names_and_symlink_target_not_followed(self):
        self.payload()
        odd = self.migration / 'dotfiles' / '隱藏 name\nwith\\slash\t.txt'
        odd.write_text('special')
        (self.migration / 'dotfiles/.hidden').write_text('hidden')
        outside = self.root / 'outside'
        outside.write_text('external')
        link = self.migration / 'dotfiles/link'
        link.symlink_to(outside)
        (self.migration / 'dotfiles/dangling').symlink_to('missing\nname')
        self.seal()
        outside.write_text('external changed')
        self.assertEqual(self.integrity('verify', self.migration).returncode, 0)
        data = json.loads((self.migration / 'manifest.json').read_text())
        paths = [base64.b64decode(e['path_b64']) for e in data['entries']]
        self.assertIn(os.fsencode(str(odd.relative_to(self.migration))), paths)
        self.assertNotIn(b'manifest.json', paths)
        link.unlink()
        link.symlink_to('different-target')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), {})

    def test_missing_modified_extra_or_incomplete_backup_blocks_before_writes(self):
        self.payload()
        self.seal()
        path = self.migration / 'developer/codex/config.toml'
        for action in ('modified', 'missing', 'extra', 'manifest-missing'):
            with self.subTest(action=action):
                path.write_text('new-codex')
                extra = self.migration / 'extra'
                if extra.exists(): extra.unlink()
                self.seal()
                if action == 'modified': path.write_text('changed')
                elif action == 'missing': path.unlink()
                elif action == 'extra': extra.write_text('added')
                else: (self.migration / 'manifest.json').unlink()
                result = self.restore()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), {})

    def test_legacy_backup_still_restores_with_warning(self):
        self.payload()
        (self.home / '.nvm').mkdir()
        result = self.restore()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('未驗證', result.stdout)
        self.assertEqual((self.home / 'Documents/Codex/note.md').read_text(), 'new-document')

    def test_dry_run_has_no_data_or_staging_changes(self):
        self.payload()
        self.seal()
        self.file('.codex/keep', 'old')
        before = self.snapshot()
        result = self.restore(dry=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))
        self.assertIn('AI 批次', result.stdout)

    def test_prepared_copy_failure_or_corruption_never_changes_destinations(self):
        self.payload()
        self.seal()
        self.file('.codex/old', 'original')
        before = self.snapshot()
        for variable in ('FAIL_STAGE', 'CORRUPT_STAGE'):
            with self.subTest(variable=variable):
                self.env[variable] = '1'
                result = self.restore()
                del self.env[variable]
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))

    def test_second_install_failure_rolls_back_present_and_absent_destinations(self):
        self.payload()
        self.seal()
        self.env['FAIL_INSTALL'] = '1'
        self.env['PARTIAL_INSTALL'] = '1'
        for existed in (True, False):
            with self.subTest(existed=existed):
                for path in (self.home / '.codex', self.home / '.claude'):
                    if path.exists(): shutil.rmtree(path)
                if existed:
                    self.file('.codex/original', 'old-codex')
                    self.file('.claude/original', 'old-claude')
                before = self.snapshot()
                result = self.restore()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('已反向回復', result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))
                self.assertFalse(list(self.home.glob('*.before-restore-*')))

    def test_failed_rollback_preserves_rescue_and_originals(self):
        self.payload()
        self.seal()
        self.file('.codex/original', 'old-codex')
        self.file('.claude/original', 'old-claude')
        self.env.update(FAIL_INSTALL='1', FAIL_ROLLBACK='1')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AI 回復失敗', result.stderr)
        work, = self.tmp.glob('mac-migrate-ai.*')
        self.assertTrue((work / 'journal.txt').exists())
        self.assertTrue((work / 'rescue/codex/config.toml').exists())
        self.assertTrue((work / 'staged/claude-code/settings.json').exists())
        for name, content in (('.codex', 'old-codex'), ('.claude', 'old-claude')):
            original, = self.home.glob(name + '.before-restore-*')
            self.assertEqual((original / 'original').read_text(), content)

    def test_process_reopened_after_staging_aborts_before_replacement(self):
        self.payload({'codex': {'config.toml': 'new'}})
        self.seal()
        self.file('.codex/keep', 'old')
        before = self.snapshot()
        # Initial check: 2 names; batch initial check: 2; final pre-commit check then fails.
        self.env['REOPEN_AFTER'] = '4'
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('程序仍在執行', result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))

    def test_output_inside_source_rejected_before_rotation(self):
        source = self.home / 'Documents/Codex'
        source.mkdir(parents=True)
        old = source / 'mac-migration'
        old.mkdir()
        (old / 'keep').write_text('previous')
        result = self.run_backup(cwd=source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('拒絕備份自身', result.stderr)
        self.assertEqual((old / 'keep').read_text(), 'previous')
        self.assertFalse(list(source.glob('mac-migration-*')))

    def test_staging_inside_destination_rejected(self):
        self.payload()
        self.seal()
        self.file('.codex/keep', 'old')
        self.env['TMPDIR'] = str(self.home / '.codex')
        before = self.snapshot()
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        # The command stub's counter is outside app data for normal tests; here ignore it.
        (self.home / '.codex/process-count').unlink(missing_ok=True)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.home.rglob('mac-migrate-ai.*')))

    def test_symlink_root_and_overlapping_destinations_rejected(self):
        self.payload()
        self.seal()
        self.env['CLAUDE_CONFIG_DIR'] = self.env['CODEX_HOME']
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), {})
        self.env['CLAUDE_CONFIG_DIR'] = str(self.home / '.claude')
        root = self.migration / 'developer/codex'
        shutil.rmtree(root)
        root.symlink_to(self.root / 'outside')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), {})

    def test_late_failure_removes_new_destination_and_empty_parent(self):
        self.payload()
        self.seal()
        self.file('.codex/original', 'codex')
        self.file('.claude/original', 'claude')
        before = self.snapshot()
        self.env.update(FAIL_INSTALL='1', FAIL_INSTALL_ID='codex-documents', PARTIAL_INSTALL='1')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.home / 'Documents').exists())

    def test_failed_original_rename_does_not_discard_original(self):
        self.payload()
        self.seal()
        self.file('.codex/original', 'codex')
        self.file('.claude/original', 'claude')
        before = self.snapshot()
        self.env['FAIL_SAVE'] = '1'
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), before)

    def test_partial_save_preserves_both_copies_and_rescue_data(self):
        self.payload()
        self.seal()
        self.file('.codex/original', 'old-codex')
        self.file('.claude/original', 'old-claude')
        self.env.update(FAIL_SAVE='1', PARTIAL_SAVE='1')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AI 回復失敗', result.stderr)
        self.assertEqual((self.home / '.codex/original').read_text(), 'old-codex')
        self.assertEqual((self.home / '.claude/original').read_text(), 'old-claude')
        saved, = self.home.glob('.claude.before-restore-*')
        self.assertEqual((saved / 'partial').read_text(), 'partial-save')
        self.assertFalse((saved / 'original').exists())
        work, = self.tmp.glob('mac-migrate-ai.*')
        self.assertTrue((work / 'journal.txt').exists())
        self.assertEqual((work / 'staged/claude-code/settings.json').read_text(), 'new-claude')
        self.assertEqual((work / 'rescue/codex/config.toml').read_text(), 'new-codex')
        self.assertIn(str(work), result.stderr.replace('\\ ', ' '))
        self.assertIn(str(saved), result.stderr.replace('\\ ', ' '))
        self.assertFalse((self.home / 'Documents').exists())

    def test_completed_save_then_failure_restores_originals(self):
        self.payload()
        self.seal()
        self.file('.codex/original', 'old-codex')
        self.file('.claude/original', 'old-claude')
        before = self.snapshot()
        self.env.update(FAIL_SAVE='1', SAVE_THEN_FAIL='1')
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('已反向回復', result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(list(self.tmp.glob('mac-migrate-ai.*')))

    def test_reopened_process_during_backup_leaves_incomplete_marker(self):
        self.file('.codex/config.toml')
        self.env['REOPEN_AFTER'] = '2'
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.migration / 'backup-format').exists())
        self.assertFalse((self.migration / 'manifest.json').exists())
        self.assertNotEqual(self.integrity('verify', self.migration).returncode, 0)

    def test_read_only_manifest_and_missing_manifest_metadata(self):
        self.payload()
        self.seal()
        (self.migration / 'manifest.json').write_text('{broken json')
        self.assertNotEqual(self.restore().returncode, 0)
        self.seal()
        data = json.loads((self.migration / 'manifest.json').read_text())
        data['version'] = 99
        (self.migration / 'manifest.json').write_text(json.dumps(data))
        self.assertNotEqual(self.restore().returncode, 0)
        self.seal()
        # Verification needs no write access (e.g. mounted read-only DMG).
        (self.migration / 'manifest.json').chmod(0o400)
        self.migration.chmod(0o500)
        try:
            self.assertEqual(self.integrity('verify', self.migration).returncode, 0)
        finally:
            self.migration.chmod(0o700)
        self.assertEqual(self.snapshot(), {})

    def test_valid_manifest_does_not_authorize_symlink_data_root(self):
        self.payload()
        root = self.migration / 'developer/codex'
        outside = self.root / 'outside-codex'
        outside.mkdir()
        (outside / 'config').write_text('outside')
        shutil.rmtree(root)
        root.symlink_to(outside)
        self.seal()
        result = self.restore()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must not be a symlink', result.stderr)
        self.assertEqual(self.snapshot(), {})
