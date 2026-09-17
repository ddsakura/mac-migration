"""End-to-end developer backup/restore with fake HOME and command fixtures."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]


class DeveloperMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='developer migration ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = self.root / 'old'
        self.new = self.root / 'new'
        self.old.mkdir()
        self.new.mkdir()
        (self.new / '.nvm').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands.log'
        stub = self.bin / 'stub'
        stub.write_text(f'''#!{sys.executable}
import json, os, pathlib, plistlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as f:
    f.write(json.dumps([name] + args) + '\\n')
if name == 'pgrep':
    sys.exit(int(os.environ.get('FIXTURE_PGREP_STATUS', '1')))
elif name == 'defaults':
    if args[0] == 'export':
        if args[1] in ('com.apple.dock', 'NSGlobalDomain', 'com.openai.chat'):
            sys.stdout.buffer.write(plistlib.dumps({{'autohide': False, 'tilesize': 73}}))
        else:
            sys.exit(1)
    elif args[0] == 'import':
        if args[1] == os.environ.get('FIXTURE_FAIL_DOMAIN'):
            sys.exit(1)
        data = subprocess.check_output(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', args[2]])
        plistlib.loads(data)
elif name == 'code' and '--list-extensions' in args:
    print('publisher.extension@1.2.3')
''')
        stub.chmod(0o700)
        for name in ('pgrep', 'defaults', 'brew', 'xcode-select', 'code', 'killall', 'sw_vers',
                     'xcodebuild', 'node', 'npm', 'ruby', 'python3', 'java', 'go', 'rustc', 'swift'):
            (self.bin / name).symlink_to(stub)

    def env(self, home):
        return {**os.environ, 'HOME': str(home), 'CODEX_HOME': str(home / 'custom-codex'),
                'CLAUDE_CONFIG_DIR': str(home / 'custom-claude'),
                'PATH': f'{self.bin}:/usr/bin:/bin', 'FIXTURE_LOG': str(self.log)}

    def write(self, home, path, text):
        target = home / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def populate(self):
        self.files = {
            'custom-codex/config.toml': 'model = "fixture"\n',
            'custom-codex/sessions/session.jsonl': '{"fixture": true}\n',
            'custom-claude/settings.json': '{}\n',
            'custom-claude/skills/demo/SKILL.md': 'fixture skill\n',
            '.claude.json': '{"mcpServers": {}}\n',
            '.agents/skills/demo/SKILL.md': 'shared skill\n',
            'Library/Application Support/Claude/claude_desktop_config.json': '{}\n',
            'Library/Application Support/Code/User/settings.json': '{"editor.fontSize": 17}\n',
            'Library/Application Support/Code/User/snippets/demo.json': '{}\n',
            '.vim/colors/custom.vim': 'fixture\n',
            '.emacs': '(message "fixture")\n',
            '.curlrc': 'retry = 3\n', '.wgetrc': 'tries = 3\n',
            '.ssh/config': 'Include config.d/*\n',
            '.ssh/config.d/work': 'Host work\n  IdentityFile ~/.ssh/keys/work-secret\n',
            '.ssh/keys/work-secret': 'FAKE PRIVATE KEY fixture\n',
            '.ssh/known_hosts': 'fixture-host\n',
        }
        for path, text in self.files.items():
            self.write(self.old, path, text)
        (self.old / 'custom-codex/skill-link').symlink_to('../custom-claude/skills')

    def backup(self, full=True):
        result = subprocess.run(['/bin/bash', str(REPO / 'backup.sh')], cwd=self.root,
                                env=self.env(self.old), input='y\nn\n' if full else 'n\nn\n',
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.root / 'mac-migration'

    def restore(self, migration, dry=False, answers='y\ny\ny\n'):
        args = ['/bin/bash', str(REPO / 'restore.sh'), '--migration-dir', str(migration)]
        if dry:
            args.append('--dry-run')
        result = subprocess.run(args, cwd=self.root, env=self.env(self.new),
                                input=answers, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_roundtrip_custom_ai_editor_ssh_and_defaults(self):
        self.populate()
        migration = self.backup()
        self.assertEqual((migration / 'extensions/code.txt').read_text(), 'publisher.extension@1.2.3\n')
        # Extension installation has a separate preview test; don't run any host editor.
        shutil.rmtree(migration / 'extensions')
        subprocess.run(['/usr/bin/perl', str(REPO / 'migration-integrity.pl'), 'create', str(migration)], check=True, capture_output=True)
        self.write(self.new, 'custom-codex/state.sqlite-wal', 'stale WAL\n')
        self.write(self.new, '.ssh/local-only', 'keep\n')
        self.restore(migration)
        for path, text in self.files.items():
            self.assertEqual((self.new / path).read_text(), text, path)
        self.assertFalse((self.new / 'custom-codex/state.sqlite-wal').exists())
        saved, = self.new.glob('custom-codex.before-restore-*')
        self.assertEqual((saved / 'state.sqlite-wal').read_text(), 'stale WAL\n')
        self.assertTrue((self.new / 'custom-codex/skill-link').is_symlink())
        self.assertEqual((self.new / '.ssh/local-only').read_text(), 'keep\n')
        self.assertEqual((self.new / '.ssh/keys/work-secret').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.new / '.ssh/keys').stat().st_mode & 0o777, 0o700)
        log = self.log.read_text()
        self.assertIn('["defaults", "import", "com.apple.dock"', log)
        self.assertNotIn('["defaults", "write"', log)
        with (migration / 'defaults/com_apple_dock.plist').open('rb') as f:
            self.assertEqual(plistlib.load(f)['tilesize'], 73)

    def test_declining_full_ssh_omits_custom_private_keys(self):
        self.populate()
        migration = self.backup(full=False)
        self.assertFalse((migration / 'ssh-format').exists())
        self.assertFalse((migration / 'ssh/keys').exists())
        self.assertTrue((migration / 'ssh/config').exists())
        self.assertTrue((migration / 'ssh/known_hosts').exists())

    def test_dry_run_does_not_touch_home_or_import_defaults(self):
        self.populate()
        migration = self.backup()
        self.write(self.new, 'custom-codex/config.toml', 'keep\n')
        before = {str(p): p.read_bytes() for p in self.new.rglob('*') if p.is_file()}
        self.log.write_text('')
        result = self.restore(migration, dry=True)
        after = {str(p): p.read_bytes() for p in self.new.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(list(self.new.glob('*.before-restore-*')))
        self.assertIn('會還原完整資料', result.stdout)
        self.assertIn('會合併完整 SSH', result.stdout)
        self.assertIn('會從備份匯入偏好設定: com.apple.dock', result.stdout)
        self.assertNotIn('["defaults", "import"', self.log.read_text())
        self.assertNotIn('--install-extension', self.log.read_text())

    def test_legacy_defaults_parseable_and_invalid(self):
        migration = self.root / 'mac-migration'
        (migration / 'defaults').mkdir(parents=True)
        (migration / 'ssh').mkdir()
        (migration / 'defaults/com_apple_dock.txt').write_text('{ autohide = 0; tilesize = 73; }')
        (migration / 'defaults/com_apple_finder.txt').write_text('not a plist')
        result = self.restore(migration, answers='n\ny\n')
        self.assertIn('略過無法解析', result.stdout)
        self.assertIn('["defaults", "import", "com.apple.dock"', self.log.read_text())
        self.assertNotIn('["defaults", "import", "com.apple.finder"', self.log.read_text())

    def test_snapshot_copy_failure_preserves_existing_data(self):
        source = self.root / 'snapshot'
        source.mkdir()
        (source / 'config').write_text('new')
        dest = self.write(self.new, 'custom-codex/config', 'old').parent
        stub = self.bin / 'rsync'
        stub.write_text('#!/bin/sh\nexit 1\n')
        stub.chmod(0o700)
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1"; restore_snapshot "$2" "$3"', '_',
                                 str(REPO / 'migration-common.sh'), str(source), str(dest)],
                                env=self.env(self.new), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((dest / 'config').read_text(), 'old')
        self.assertFalse(list(self.new.glob('*.before-restore-*')))
        self.assertFalse(list(self.new.glob('.mac-migrate-restore.*')))

    def test_snapshot_refuses_home_as_destination(self):
        source = self.root / 'snapshot'
        source.mkdir()
        self.write(self.new, 'keep', 'original')
        result = subprocess.run(['/bin/bash', '-c',
                                 'source "$1"; restore_snapshot "$2" "$3"', '_',
                                 str(REPO / 'migration-common.sh'), str(source), str(self.new)],
                                env=self.env(self.new), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.new / 'keep').read_text(), 'original')

    def test_decline_full_ssh_restores_basics_without_keys(self):
        self.populate()
        migration = self.backup()
        shutil.rmtree(migration / 'extensions')
        subprocess.run(['/usr/bin/perl', str(REPO / 'migration-integrity.pl'), 'create', str(migration)], check=True, capture_output=True)
        result = self.restore(migration, answers='n\nn\nn\n')
        for item in ('config', 'known_hosts'):
            self.assertEqual((self.new / '.ssh' / item).read_text(),
                             (self.old / '.ssh' / item).read_text())
        self.assertFalse((self.new / '.ssh/keys').exists())
        self.assertFalse((self.new / '.ssh/config.d').exists())
        self.assertIn('已略過完整 SSH 還原', result.stdout)
        self.assertNotIn('["defaults", "import"', self.log.read_text())

    def test_blank_and_eof_confirmations_decline(self):
        self.populate()
        migration = self.backup()
        shutil.rmtree(migration / 'extensions')
        subprocess.run(['/usr/bin/perl', str(REPO / 'migration-integrity.pl'), 'create', str(migration)], check=True, capture_output=True)
        self.restore(migration, answers='\n')
        self.assertFalse((self.new / 'custom-codex').exists())
        self.assertTrue((self.new / '.ssh/config').exists())
        self.assertFalse((self.new / '.ssh/keys').exists())
        self.assertNotIn('["defaults", "import"', self.log.read_text())

    def test_failed_defaults_import_continues_without_restarting_failed_domain(self):
        migration = self.root / 'mac-migration'
        (migration / 'defaults').mkdir(parents=True)
        (migration / 'ssh').mkdir()
        for domain in ('com.apple.dock', 'com.apple.finder', 'NSGlobalDomain'):
            target = migration / 'defaults' / (domain.replace('.', '_') + '.plist')
            target.write_bytes(plistlib.dumps({'fixture': True}))
        for failed, failed_process, other_process in (
            ('com.apple.dock', 'Dock', 'Finder'),
            ('com.apple.finder', 'Finder', 'Dock'),
        ):
            with self.subTest(domain=failed):
                self.log.write_text('')
                with patch.dict(os.environ, {'FIXTURE_FAIL_DOMAIN': failed}):
                    result = self.restore(migration, answers='n\ny\n')
                log = self.log.read_text()
                self.assertIn('匯入失敗，略過並繼續其他項目: ' + failed, result.stdout)
                self.assertNotIn('已匯入: ' + failed, result.stdout)
                self.assertNotIn('["killall", "' + failed_process + '"]', log)
                self.assertIn('["killall", "' + other_process + '"]', log)
                self.assertIn('["defaults", "import", "NSGlobalDomain"', log)
                self.assertIn('7. 開發工具', result.stdout)
