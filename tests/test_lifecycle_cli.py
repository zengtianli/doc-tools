"""DocKit's command words, end to end and off screen.

The app executable answers `status`, `settings`, `config …`, `update check`, `update install` and `help` itself,
before any NSApplication exists (Sources/DocKitCLI.swift). `config` and `update` are the items of the
“配置与更新…” window, run by the shared layer (Sources/AppLifecycleCLI.swift) on the window's own configuration.
This test drives the compiled executable as real processes:

1. the top-level help lists every command, the --json shapes, the exit codes and what stays in the window;
2. `status` reports the bundle's version and build, the window's status line (ready / engine not ready) and
   the remembered settings, and writes nothing;
3. `settings set` validates against the operation catalog, and a freshly started app selects what it wrote;
4. `config …` reads and writes the same preferences the window's configuration does, and `config status`
   carries the sync status sentence the window shows under the iCloud switch (`sync_status`);
5. a running app follows `config sync` and `config import` typed in another process and never writes an old
   value back: the executable is started a second time as the app itself (`--lifecycle-follow-probe`: the
   production wiring, the real ContentView and the shared window, activation policy prohibited, nothing ever
   ordered in). Every verdict reads the stored values from a fresh process; two commands back to back are
   part of it, and so is an import made while sync is on and the app is running;
6. `update install` is the window's upgrade button as a command. This build is ad-hoc signed and its channel is
   GitHub, so the shared installer never replaces it (the window's button is「下载新版…」): with nothing newer
   the command exits 0 and installs nothing, with something newer it exits 1 with `manual_install` and the
   package address. Neither case downloads or replaces anything.

Everything is isolated: a throwaway bundle with a test bundle identifier, a throwaway named preferences domain,
temporary support and "cloud" directories, a private notification channel. No window is shown, nothing reaches
the Dock, `update check` and `update install` run with the network denied, no installed app is signalled and
your own settings are never opened. DOCKIT_TEST_ONLINE=1 adds one test that reads the public release record
from GitHub (still on throwaway bundles; nothing is downloaded or installed).

    DOCKIT_TEST_APP=/path/to/Test.app python3 tests/test_lifecycle_cli.py     (scripts/accept/lifecycle.sh builds it)
    DOCKIT_APP=/path/to/DocKit.app python3 tests/test_lifecycle_cli.py AssembledBundleTests   (read commands only)
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
TEST_APP = os.environ.get('DOCKIT_TEST_APP')
ONLINE = os.environ.get('DOCKIT_TEST_ONLINE') == '1'
BUNDLE = 'io.github.zengtianli.DocTools.LifecycleTest'
PRODUCT = 'io.github.zengtianli.DocTools'
SANDBOX = Path('/usr/bin/sandbox-exec')
NO_NETWORK = '(version 1) (allow default) (deny network*)'
OFF = 'iCloud 配置同步已关闭'
LAST, FORMATS = 'dockit.lastOperation', 'dockit.targetFormats'


def clock():
    return time.monotonic()  # does not advance while the Mac sleeps: a nap cannot fail a wait


def forget(suite):
    subprocess.run(['/usr/bin/defaults', 'delete', suite], capture_output=True, timeout=30)
    (Path.home() / 'Library/Preferences' / (suite + '.plist')).unlink(missing_ok=True)


@unittest.skipUnless(TEST_APP and Path(TEST_APP).is_dir(), 'set DOCKIT_TEST_APP to a test bundle (scripts/accept/lifecycle.sh builds one)')
class CommandWordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = Path(TEST_APP).resolve()
        cls.info = plistlib.loads((cls.app / 'Contents/Info.plist').read_bytes())
        assert cls.info['CFBundleIdentifier'] == BUNDLE, 'the test bundle must carry the test bundle identifier'
        cls.binary = cls.app / 'Contents/MacOS' / cls.info['CFBundleExecutable']
        cls.folder = tempfile.TemporaryDirectory(prefix='dockit-lifecycle-')
        cls.root = Path(cls.folder.name).resolve()
        cls.suite = BUNDLE + '.' + uuid.uuid4().hex
        cls.support, cls.cloud = cls.root / 'support', cls.root / 'cloud'
        cls.env = dict(os.environ, APP_LIFECYCLE_SUPPORT_DIR=str(cls.support), APP_LIFECYCLE_CLOUD_DIR=str(cls.cloud),
                       DOCKIT_LIFECYCLE_SUITE=cls.suite)
        for name in ('APP_LIFECYCLE_FOLLOW_CHANNEL', 'DOCKIT_CLI_NAME', 'DOCKIT_BACKGROUND', 'DOCKIT_DEMO_OP', 'DOCKIT_DEMO_FILES'):
            cls.env.pop(name, None)
        cls.followers = []

    @classmethod
    def tearDownClass(cls):
        for process in cls.followers:
            process.kill()
            process.wait(timeout=10)
        forget(cls.suite)
        cls.folder.cleanup()

    def setUp(self):
        """Every test starts from nothing remembered, sync off, no support or cloud directory."""
        subprocess.run(['/usr/bin/defaults', 'delete', self.suite], capture_output=True, timeout=30)
        for folder in (self.support, self.cloud):
            shutil.rmtree(folder, ignore_errors=True)

    # The command as it is typed: the app executable with the words after it.
    def dockit(self, *words, env=None, cwd=None):
        return subprocess.run([str(self.binary), *words], env=env or self.env, cwd=cwd, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=90)

    def call(self, *words, expect=0, env=None):
        done = self.dockit(*words, '--json', env=env)
        self.assertEqual(done.returncode, expect, (words, done.stdout, done.stderr))
        body = json.loads(done.stdout)
        self.assertIs(body['ok'], expect == 0, body)
        if expect:
            self.assertTrue(body['error']['code'] and body['error']['message'], body)
        return body

    def stored(self, key):
        """A stored preference, read by a fresh process (never by the process that wrote it)."""
        done = subprocess.run(['/usr/bin/defaults', 'export', self.suite, '-'], capture_output=True, timeout=30)
        return plistlib.loads(done.stdout).get(key) if done.returncode == 0 and done.stdout else None

    def mirrored(self):
        """What the "cloud" copy holds, read from the file (the write is atomic; a retry covers the swap)."""
        for _ in range(20):
            try:
                values = json.loads((self.cloud / (PRODUCT + '.json')).read_text())['values']
                return values.get('defaults.' + LAST), values.get('defaults.' + FORMATS)
            except (OSError, ValueError):
                time.sleep(0.02)
        return None

    def envelope(self, operation, formats):
        return {'product': PRODUCT, 'version': 1, 'values': {'defaults.' + LAST: operation, 'defaults.' + FORMATS: formats}}

    def start_app(self, env):
        state = self.root / ('app-' + uuid.uuid4().hex + '.json')
        complaints = state.with_suffix('.err')
        with complaints.open('wb') as errors:
            process = subprocess.Popen([str(self.binary), '--lifecycle-follow-probe', str(state)], env=env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errors)
        self.followers.append(process)
        deadline = clock() + 30
        while not state.exists() and clock() < deadline and process.poll() is None:
            time.sleep(0.05)
        self.assertTrue(state.exists(), complaints.read_text() or 'the app did not report')

        def seen():
            for _ in range(40):
                try:
                    return json.loads(state.read_text())
                except (OSError, ValueError):
                    time.sleep(0.02)
            raise AssertionError('app state unreadable')

        def reaches(test, seconds=8.0):
            deadline = clock() + seconds
            while clock() < deadline:
                if test(seen()):
                    return True
                time.sleep(0.05)
            return False

        def stop():
            if process in self.followers:
                process.terminate()
                process.wait(timeout=10)
                self.followers.remove(process)

        self.addCleanup(stop)  # a failed assertion must not leave the app running into the next test
        self.assertTrue(reaches(lambda s: s['operations'] > 0, 40), 'the app loaded its operations')
        return seen, reaches, stop

    # ── help

    def test_top_level_help_lists_commands_json_shapes_exit_codes_and_window_only(self):
        for words in (('help',), ('--help',), ('-h',), ('status', '--help'), ('settings', '--help')):
            done = self.dockit(*words)
            self.assertEqual((done.returncode, done.stderr), (0, ''), words)
            top = done.stdout
        shared = self.dockit('config', '--help')
        self.assertEqual(shared.returncode, 0)
        for line in ('  status ', '  settings ', '  settings set ', '  config status ', '  update check ',
                     '  config export ', '  config import ', '  config sync ', '  update install --yes '):
            self.assertIn('\n' + line, top, line)
        # The shared layer's own lines, unchanged, reach the top-level help.
        own = [line for line in shared.stdout.splitlines()
               if line.startswith(('  config status', '  update check', '  config export', '  config import', '  config sync',
                                   '  update install')) and '→' not in line]
        self.assertEqual(len(own), 6, own)
        for line in own:
            self.assertIn('\n' + line + '\n', top)
        reads, writes = top.split('读命令')[1].split('写命令')[0], top.split('写命令')[1].split('--json 输出形状')[0]
        self.assertTrue('config status' in reads and 'update check' in reads and 'settings set' not in reads and 'config export' not in reads)
        self.assertTrue('同步状态' in reads and 'update install' not in reads)   # upgrading replaces the app: a write command
        self.assertTrue(all(word in writes for word in ('settings set', 'config export', 'config import', 'config sync',
                                                        'update install --yes')))
        self.assertTrue('--json' in top and '退出码' in top and '"error"' in top)
        # Every item of the window has a command now: neither help has a「暂无命令」line, and upgrading is not window-only.
        window = top.split('仅在窗口中：')[1]
        self.assertIn('打开「配置与更新…」窗口', window)
        self.assertNotIn('升级到新版', window)
        self.assertNotIn('暂无命令', top)
        self.assertNotIn('暂无命令', shared.stdout)
        self.assertIn('manual_install', top)       # what this ad-hoc build answers when a newer release exists
        self.assertIn('sync_status{text, at, from, live}', shared.stdout)
        self.assertIn('DocTools update install --yes [--dry-run] [--json]', shared.stdout)
        self.assertIn('usage: DocTools ', top)
        named = self.dockit('help', env=dict(self.env, DOCKIT_CLI_NAME='dockit public')).stdout
        self.assertIn('usage: dockit public <command>', named)
        self.assertIn('用 dockit public config status 回读', named)
        self.assertIn('用 dockit public update check 回读', named)

    def test_info_plist_lists_exactly_the_words_the_executable_answers(self):
        """Info.plist's DocKitCommandVerbs is what a wrapper reads before forwarding a word (a word the build
        does not know would open the window). Every listed word must be answered without one."""
        listed = plistlib.loads((ROOT / 'Info.plist').read_bytes())['DocKitCommandVerbs']
        self.assertEqual(sorted(listed), ['config', 'help', 'settings', 'status', 'update'])
        for word in listed:
            done = self.dockit(word, '--help')
            self.assertEqual((done.returncode, done.stderr), (0, ''), word)
            self.assertIn('usage: DocTools ', done.stdout, word)

    # ── status and settings

    def test_status_reads_version_status_line_and_settings_without_writing(self):
        status = self.call('status')
        self.assertEqual(status['command'], 'status')
        self.assertEqual(status['app'], {'name': 'DocKit', 'bundle_id': BUNDLE, 'version': self.info['CFBundleShortVersionString'],
                                         'build': self.info['CFBundleVersion'], 'path': str(self.app)})
        engine = status['engine']
        self.assertEqual((engine['ready'], engine['error'], engine['operations']), (True, None, 9))
        self.assertEqual(engine['status_line'], '已就绪 · 共 9 个操作。拖入文件开始。')  # the window's own sentence
        self.assertEqual((status['settings'], status['app_running']), ({'last_operation': None, 'target_formats': {}}, False))
        text = self.dockit('status')
        self.assertEqual(text.returncode, 0)
        self.assertIn(f"DocKit {self.info['CFBundleShortVersionString']} ({self.info['CFBundleVersion']})", text.stdout)
        self.assertIn('状态行：已就绪 · 共 9 个操作', text.stdout)
        self.assertEqual(self.call('settings')['settings'], {'last_operation': None, 'target_formats': {}})
        # Reading wrote nothing: no support or cloud directory, no preferences.
        self.assertFalse(self.support.exists() or self.cloud.exists())
        self.assertIsNone(self.stored(LAST))

    def test_status_says_engine_not_ready_when_the_bundle_has_no_backend(self):
        bare = self.root / 'Bare.app'
        (bare / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(self.binary, bare / 'Contents/MacOS' / self.binary.name)
        shutil.copy2(self.app / 'Contents/Info.plist', bare / 'Contents/Info.plist')
        done = subprocess.run([str(bare / 'Contents/MacOS' / self.binary.name), 'status', '--json'], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
        body = json.loads(done.stdout)
        self.assertEqual((done.returncode, body['ok'], body['engine']['ready'], body['engine']['operations']), (0, True, False, 0))
        self.assertEqual(body['engine']['status_line'], '文档引擎未就绪，请重新打开或重新下载 DocKit。')
        self.assertIn('加载操作列表失败', body['engine']['error'])
        refused = subprocess.run([str(bare / 'Contents/MacOS' / self.binary.name), 'settings', 'set', 'last_operation', 'convert', '--json'],
                                 env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
        self.assertEqual((refused.returncode, json.loads(refused.stdout)['error']['code']), (1, 'engine_unavailable'))
        self.assertIsNone(self.stored(LAST))

    def test_settings_set_validates_then_a_fresh_app_selects_what_it_wrote(self):
        for words, code in ((('settings', 'set', 'nope', 'x'), 'unknown_setting'), (('settings', 'set', 'last_operation', 'nope'), 'unknown_operation'),
                            (('settings', 'set', 'target_formats.nope', 'md'), 'unknown_operation'),
                            (('settings', 'set', 'target_formats.convert', 'nope'), 'unknown_target'),
                            (('settings', 'set', 'target_formats.quotes', 'md'), 'unknown_target'),
                            (('settings', 'set', 'last_operation'), 'usage'), (('settings', 'bogus'), 'usage')):
            self.assertEqual(self.call(*words, expect=2)['error']['code'], code, words)
        self.assertEqual((self.stored(LAST), self.stored(FORMATS)), (None, None))  # a refused value writes nothing
        first = self.call('settings', 'set', 'last_operation', 'convert')
        self.assertEqual((first['command'], first['changed'], first['domain']),
                         ('settings set', {'key': 'last_operation', 'from': None, 'to': 'convert'}, self.suite))
        second = self.call('settings', 'set', 'target_formats.convert', 'word')
        self.assertEqual(second['settings'], {'last_operation': 'convert', 'target_formats': {'convert': 'word'}})
        self.assertEqual((self.stored(LAST), self.stored(FORMATS)), ('convert', {'convert': 'word'}))
        self.assertEqual(self.call('settings')['settings'], second['settings'])
        self.assertEqual(self.call('status')['settings'], second['settings'])
        # The window, opened afterwards, selects what the command wrote.
        seen, reaches, stop = self.start_app(dict(self.env, APP_LIFECYCLE_FOLLOW_CHANNEL='test.' + uuid.uuid4().hex))
        self.assertTrue(reaches(lambda s: (s['selected_operation'], s['selected_target']) == ('convert', 'word')), seen())
        self.assertEqual((seen()['policy_prohibited'], seen()['windows_on_screen'], seen()['active']), (True, 0, False))
        stop()
        self.assertEqual((self.stored(LAST), self.stored(FORMATS)), ('convert', {'convert': 'word'}))  # opening changed nothing

    def test_words_and_exit_codes(self):
        cases = ((('status', '--json'), 0), (('settings',), 0), (('config', 'status', '--json'), 0), (('config', '--json'), 0),
                 (('status', '--no-such', '--json'), 2), (('status', 'extra', '--json'), 2), (('settings', '--no-such'), 2),
                 (('config', 'bogus', '--json'), 2), (('config', 'status', '--no-such', '--json'), 2), (('update', '--json'), 2),
                 (('config', 'export', '--json'), 2), (('config', 'sync', 'maybe', '--json'), 2), (('config', 'sync', 'on', '--json'), 2),
                 (('config', 'import', str(self.root / 'absent.json'), '--yes', '--json'), 1),
                 # refused on the words alone, before any release record is looked up
                 (('update', 'install', '--no-such', '--json'), 2), (('update', 'install', 'extra', '--json'), 2),
                 (('update', 'install', '--no-such'), 2))
        for words, code in cases:
            done = self.dockit(*words)
            self.assertEqual(done.returncode, code, (words, done.stdout, done.stderr))
            if '--json' in words:
                body = json.loads(done.stdout)
                self.assertIs(body['ok'], code == 0)
                self.assertEqual(body['command'].split()[0], words[0])
                if code:
                    self.assertTrue(body['error']['code'] and body['error']['message'])
            elif code:
                self.assertEqual(done.stdout, '')  # text-mode errors go to stderr
                self.assertTrue(done.stderr.strip())
        self.assertEqual(self.call('status', '--no-such', expect=2)['error']['code'], 'usage')
        self.assertEqual(self.call('config', 'status', '--no-such', expect=2)['error']['code'], 'usage')
        self.assertEqual(self.call('config', 'sync', 'on', expect=2)['error']['code'], 'confirmation_required')
        self.assertEqual(self.call('update', 'install', '--no-such', expect=2)['error']['code'], 'usage')
        # A relative path is resolved where the command was typed.
        done = self.dockit('config', 'export', '-o', 'here.json', '--json', cwd=self.root)
        self.assertEqual((done.returncode, json.loads(done.stdout)['path']), (0, str(self.root / 'here.json')))

    # ── config and update

    def test_config_reads_and_writes_the_windows_own_settings(self):
        self.call('settings', 'set', 'last_operation', 'merge')
        self.call('settings', 'set', 'target_formats.convert', 'md')
        status = self.call('config', 'status')
        self.assertEqual((status['command'], status['has_settings'], status['sync_enabled'], status['problem']), ('config status', True, False, None))
        self.assertEqual(status['keys'], ['defaults.' + LAST, 'defaults.' + FORMATS])
        # The sentence under the switch: nothing has synced yet, so it is what the window shows when it opens.
        self.assertEqual(status['sync_status'], {'text': OFF, 'at': None, 'from': 'derived', 'live': False})
        self.assertIn('\n同步状态：' + OFF, self.dockit('config', 'status').stdout)
        self.assertFalse(self.support.exists() or self.cloud.exists())  # reading writes nothing
        exported = self.root / 'out.json'
        exported.unlink(missing_ok=True)
        first = self.call('config', 'export', '-o', str(exported))
        envelope = json.loads(exported.read_text())
        self.assertEqual((envelope, first['bytes']), (self.envelope('merge', {'convert': 'md'}), exported.stat().st_size))
        self.assertEqual(self.call('config', 'export', '-o', str(exported), expect=2)['error']['code'], 'file_exists')
        self.assertEqual(json.loads(self.dockit('config', 'export', '-o', '-').stdout), envelope)

        incoming = self.root / 'in.json'
        incoming.write_text(json.dumps(self.envelope('split', {'convert': 'csv'})))
        self.assertEqual(self.call('config', 'import', str(incoming), expect=2)['error']['code'], 'confirmation_required')
        foreign = self.root / 'foreign.json'
        foreign.write_text(json.dumps(dict(self.envelope('split', {}), product='someone.else')))
        self.assertEqual(self.call('config', 'import', str(foreign), '--yes', expect=1)['error']['code'], 'import_rejected')
        self.assertEqual((self.stored(LAST), self.stored(FORMATS)), ('merge', {'convert': 'md'}))
        imported = self.call('config', 'import', str(incoming), '--yes')
        self.assertTrue(imported['imported'] and 'sync' not in imported)
        self.assertEqual((self.stored(LAST), self.stored(FORMATS)), ('split', {'convert': 'csv'}))
        self.assertEqual(self.call('settings')['settings'], {'last_operation': 'split', 'target_formats': {'convert': 'csv'}})
        self.assertEqual(len(list((self.support / PRODUCT / 'Backups').iterdir())), 1)
        self.assertFalse(self.cloud.exists())  # sync is off: nothing leaves the machine

        dry = self.call('config', 'sync', 'on', '--dry-run')
        self.assertTrue(dry['dry_run'] and dry['would_change'] and not self.call('config', 'status')['sync_enabled'])
        on = self.call('config', 'sync', 'on', '--yes')
        self.assertEqual((on['changed'], on['sync_enabled'], on['check_with'], self.mirrored()),
                         (True, True, 'DocTools config status', ('split', {'convert': 'csv'})))
        after = self.call('config', 'status')
        self.assertTrue(after['sync_enabled'])
        # The app is not running: the sentence is the one that sync pass left, the same the command reported.
        self.assertEqual((after['sync_status']['text'], after['sync_status']['from'], after['sync_status']['live']),
                         (on['status'], 'record', False))
        self.assertRegex(after['sync_status']['at'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d')
        self.assertNotEqual(on['status'], OFF)
        self.assertIs(self.call('config', 'sync', 'on', '--yes')['changed'], False)
        self.assertIs(self.call('config', 'sync', 'off', '--yes')['sync_enabled'], False)
        closed = self.call('config', 'status')
        self.assertEqual((closed['sync_enabled'], closed['sync_status']['text']), (False, OFF))

    @unittest.skipUnless(SANDBOX.exists(), 'sandbox-exec not available')
    def test_update_check_names_this_bundle_and_its_channel_with_the_network_denied(self):
        done = subprocess.run([str(SANDBOX), '-p', NO_NETWORK, str(self.binary), 'update', 'check', '--json'], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
        body = json.loads(done.stdout)
        self.assertEqual((done.returncode, body['ok'], body['command'], body['error']['code']), (1, False, 'update check', 'check_incomplete'))
        self.assertEqual(body['current'], {'version': self.info['CFBundleShortVersionString'], 'build': self.info['CFBundleVersion']})
        self.assertEqual(body['source'], {'kind': 'github', 'repository': 'zengtianli/doc-tools'})
        self.assertFalse(self.support.exists() or self.cloud.exists())  # nothing downloaded, nothing installed

    def sealed(self, app=None):
        """The bytes a replacement would change: the executable and the Info.plist of a bundle."""
        app = app or self.app
        return [(path.name, path.read_bytes()) for path in (app / 'Contents/MacOS' / self.binary.name, app / 'Contents/Info.plist')]

    @unittest.skipUnless(SANDBOX.exists(), 'sandbox-exec not available')
    def test_update_install_without_a_release_record_replaces_nothing(self):
        """`update install` looks the release up first. With the network denied it has no record: exit 1,
        `check_incomplete`, whatever the flags — never a guess, never a replacement."""
        before = self.sealed()
        current = {'version': self.info['CFBundleShortVersionString'], 'build': self.info['CFBundleVersion']}
        for flags in (('--yes',), ('--dry-run',), (), ('--yes', '--dry-run')):
            done = subprocess.run([str(SANDBOX), '-p', NO_NETWORK, str(self.binary), 'update', 'install', *flags, '--json'],
                                  env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
            body = json.loads(done.stdout)
            self.assertEqual((done.returncode, body['ok'], body['command'], body['error']['code']),
                             (1, False, 'update install', 'check_incomplete'), flags)
            self.assertEqual((body['current'], body['source']), (current, {'kind': 'github', 'repository': 'zengtianli/doc-tools'}))
            self.assertNotIn('installed', body)
        text = subprocess.run([str(SANDBOX), '-p', NO_NETWORK, str(self.binary), 'update', 'install', '--yes'], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
        self.assertEqual((text.returncode, text.stdout), (1, ''))
        self.assertTrue(text.stderr.strip())
        self.assertEqual(self.sealed(), before)
        self.assertFalse(self.support.exists() or self.cloud.exists())  # nothing downloaded, nothing backed up

    @unittest.skipUnless(ONLINE, 'set DOCKIT_TEST_ONLINE=1 to read the public release record from GitHub once')
    def test_update_install_with_the_public_release_record_installs_nothing(self):
        """The public release record is readable. This build is ad-hoc signed and its channel is GitHub, so the
        shared installer does not replace it (the window's button is「下载新版…」, not「升级到新版…」):
        nothing newer → exit 0 with `installed: false`; something newer → exit 1 `manual_install` with the package
        address. `--dry-run` and a missing `--yes` get the same answers. Nothing is downloaded or replaced."""
        before = self.sealed()
        current = {'version': self.info['CFBundleShortVersionString'], 'build': self.info['CFBundleVersion']}
        checked = self.call('update', 'check')
        self.assertEqual((checked['update_available'], checked['upgrade']['in_app'], checked['upgrade']['command']), (False, False, None))
        for flags in (('--yes',), ('--dry-run',), ()):
            same = self.call('update', 'install', *flags)   # the test bundle is ahead of every release
            self.assertEqual((same['command'], same['installed'], same['current'], same['latest']),
                             ('update install', False, current, checked['latest']), flags)
            self.assertIn(same['state'], ('up_to_date', 'ahead_of_channel'))
            self.assertTrue(same['message'])
            self.assertNotIn('dry_run', same)
        self.assertIn('不需要升级', self.dockit('update', 'install', '--yes').stdout)
        self.assertEqual(self.sealed(), before)

        # An older copy of the same executable: a newer release exists.
        older = self.root / ('older-' + uuid.uuid4().hex[:8]) / 'DocKit.app'
        (older / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(self.binary, older / 'Contents/MacOS' / self.binary.name)
        (older / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(self.info, CFBundleShortVersionString='0.0.1', CFBundleVersion='1')))
        untouched = self.sealed(older)
        binary = older / 'Contents/MacOS' / self.binary.name

        def typed(*words):
            done = subprocess.run([str(binary), *words, '--json'], env=self.env, capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL, timeout=90)
            return done.returncode, json.loads(done.stdout)

        code, newer = typed('update', 'check')
        self.assertEqual((code, newer['state'], newer['update_available']), (0, 'update_available', True))
        self.assertEqual((newer['upgrade']['in_app'], newer['upgrade']['button'], newer['upgrade']['command']), (False, '下载新版…', None))
        self.assertTrue(newer['upgrade']['download_url'].startswith('https://github.com/zengtianli/doc-tools/'))
        for flags in (('--yes',), ('--dry-run',), ()):
            code, refused = typed('update', 'install', *flags)
            self.assertEqual((code, refused['ok'], refused['command'], refused['error']['code']),
                             (1, False, 'update install', 'manual_install'), flags)
            self.assertEqual((refused['download_url'], refused['current']),
                             (newer['upgrade']['download_url'], {'version': '0.0.1', 'build': '1'}))
            self.assertNotIn('installed', refused)
        self.assertEqual(self.sealed(older), untouched)
        self.assertEqual(sorted(path.name for path in older.parent.iterdir()), ['DocKit.app'])   # no download, no leftover beside it
        self.assertFalse((self.support / 'backups').exists() or (self.support / 'trash').exists())

    # ── a running app

    def test_a_running_app_follows_the_command_and_never_writes_an_old_value_back(self):
        live = dict(self.env, APP_LIFECYCLE_FOLLOW_CHANNEL='test.' + uuid.uuid4().hex)
        self.call('settings', 'set', 'last_operation', 'clean')
        seen, reaches, stop = self.start_app(live)

        def holds(want, seconds=1.0):
            """The app's configuration, the window's switch and the stored switch (read by a fresh process) all stay put."""
            deadline = clock() + seconds
            while clock() < deadline:
                now = seen()
                if now['enabled'] is not want or now['window_switch'] is not want or self.call('config', 'status')['sync_enabled'] is not want:
                    return False
                time.sleep(0.05)
            return True

        first = seen()
        # The app is running as an app, and nothing of it is on screen.
        self.assertEqual((first['policy_prohibited'], first['windows_on_screen'], first['active']), (True, 0, False))
        self.assertTrue(all(first['window_built'].values()), first['window_built'])  # the shared window, built as the menu item builds it
        self.assertEqual((first['enabled'], first['window_switch'], first['status'], first['selected_operation']), (False, False, OFF, 'clean'))
        for attempt in range(3):
            on = self.call('config', 'sync', 'on', '--yes', env=live)
            self.assertTrue(on['changed'] and on['app_running'], on)  # the command saw the running app
            self.assertTrue(reaches(lambda s: s['enabled'] is True and s['window_switch'] is True and s['status'] != OFF), f'follows sync on ({attempt + 1})')
            self.assertTrue(holds(True), f'sync on is not written back ({attempt + 1})')
            self.call('config', 'sync', 'off', '--yes', env=live)
            self.assertTrue(reaches(lambda s: s['enabled'] is False and s['window_switch'] is False and s['status'] == OFF), f'follows sync off ({attempt + 1})')
            self.assertTrue(holds(False), f'sync off is not written back ({attempt + 1})')
        # Two commands back to back: whatever the app does about the first must not undo the second after it has returned.
        for attempt in range(3):
            self.call('config', 'sync', 'on', '--yes', env=live)
            self.call('config', 'sync', 'off', '--yes', env=live)
            self.assertTrue(reaches(lambda s: s['enabled'] is False and s['window_switch'] is False and s['status'] == OFF), f'settles off after on, off ({attempt + 1})')
            self.assertTrue(holds(False, 1.5), f'on, off back to back stays off ({attempt + 1})')
        self.call('config', 'sync', 'on', '--yes', env=live)
        self.call('config', 'sync', 'off', '--yes', env=live)
        self.call('config', 'sync', 'on', '--yes', env=live)
        self.assertTrue(reaches(lambda s: s['enabled'] is True and s['window_switch'] is True and s['status'] != OFF), 'settles on after on, off, on')
        self.assertTrue(holds(True, 1.5), 'on, off, on back to back stays on')
        self.call('config', 'sync', 'off', '--yes', env=live)
        self.assertTrue(reaches(lambda s: s['enabled'] is False and s['window_switch'] is False and s['status'] == OFF), 'back to off')

        # An import with sync off: the app re-reads the settings, selects the imported operation and leaves the switch alone.
        incoming = self.root / 'follow.json'

        def bring(operation, formats):
            incoming.write_text(json.dumps(self.envelope(operation, formats)))
            return self.call('config', 'import', str(incoming), '--yes', env=live)

        def keeps(operation, formats, seconds=1.5, cloud=False):
            """From the moment the command returned: the stored settings (fresh process) and the cloud copy stay the imported ones."""
            deadline = clock() + seconds
            while clock() < deadline:
                if (self.stored(LAST), self.stored(FORMATS)) != (operation, formats):
                    return False
                if cloud and self.mirrored() != (operation, formats):
                    return False
                time.sleep(0.05)
            return True

        before = seen()
        bring('convert', {'convert': 'xlsx'})
        self.assertTrue(keeps('convert', {'convert': 'xlsx'}), 'the import is not undone (sync off)')
        self.assertTrue(reaches(lambda s: s['changes'] > before['changes'] and (s['selected_operation'], s['selected_target']) == ('convert', 'xlsx')),
                        ('the app re-reads imported settings', seen()))
        self.assertTrue(holds(False, 0.6), 'an import leaves the switch alone')
        self.assertEqual(self.mirrored(), ('clean', None))  # sync is off: the import did not leave the machine

        # Sync on, the app running, then imports (one of them changes a single key, two come back to back):
        # the running app must not store what it held before over what the command imported.
        self.call('config', 'sync', 'on', '--yes', env=live)
        self.assertTrue(reaches(lambda s: s['enabled'] is True and s['window_switch'] is True), 'sync on before the imports')
        for operation, formats in (('split', {'convert': 'csv'}), ('split', {'convert': 'txt'}), ('merge', {'convert': 'md'})):
            done = bring(operation, formats)
            self.assertTrue(done['sync_enabled'] and done['sync']['completed'] and done['app_running'], done)
            self.assertTrue(keeps(operation, formats, cloud=True), f'the import of {operation} {formats} is not undone (sync on)')
            self.assertTrue(reaches(lambda s: s['selected_operation'] == operation), ('the app selects the imported operation', seen()))
        bring('quotes', {'convert': 'word'})
        bring('convert', {'convert': 'csv'})
        self.assertTrue(keeps('convert', {'convert': 'csv'}, cloud=True), 'two imports back to back: the second stays')
        self.assertTrue(reaches(lambda s: (s['selected_operation'], s['selected_target']) == ('convert', 'csv')), ('the app follows the second import', seen()))
        self.assertTrue(holds(True, 0.6), 'imports leave the switch on')
        self.call('config', 'sync', 'off', '--yes', env=live)
        self.assertTrue(reaches(lambda s: s['enabled'] is False and s['window_switch'] is False and s['status'] == OFF), 'off at the end')
        self.assertTrue(keeps('convert', {'convert': 'csv'}, 0.6), 'turning sync off keeps the imported settings')

        last = seen()
        self.assertEqual((last['policy_prohibited'], last['windows_on_screen'], last['active']), (True, 0, False))
        self.assertGreater(last['tick'], first['tick'])
        stop()
        self.assertIs(self.call('config', 'status')['app_running'], False)

    def test_refusals(self):
        # An isolated run that does not say where the product's own settings are is refused before anything is read.
        partial = {key: value for key, value in self.env.items() if key != 'DOCKIT_LIFECYCLE_SUITE'}
        for words in (('status',), ('settings',), ('config', 'status'), ('settings', 'set', 'last_operation', 'convert')):
            self.assertEqual(self.call(*words, expect=1, env=partial)['error']['code'], 'isolation_incomplete', words)
            self.assertEqual(self.call(*words, expect=1, env=dict(self.env, DOCKIT_LIFECYCLE_SUITE=PRODUCT))['error']['code'], 'isolation_incomplete', words)
        # The probe mode exists for this test only: outside an isolated run the executable exits at once, before any NSApplication.
        outside = {key: value for key, value in self.env.items() if not key.startswith(('APP_LIFECYCLE_', 'DOCKIT_LIFECYCLE_'))}
        probe = subprocess.run([str(self.binary), '--lifecycle-follow-probe', str(self.root / 'never.json')], env=outside,
                               capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual((probe.returncode, (self.root / 'never.json').exists()), (64, False))


ASSEMBLED = os.environ.get('DOCKIT_APP')


@unittest.skipUnless(ASSEMBLED, 'set DOCKIT_APP to an assembled or installed DocKit.app')
class AssembledBundleTests(unittest.TestCase):
    """The shipped bundle: read commands only, on a throwaway preferences domain and temporary directories.
    The bundle's real settings are not opened, no running copy is signalled, the network is denied."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='dockit-lifecycle-app-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.app = Path(ASSEMBLED)
        self.info = plistlib.loads((self.app / 'Contents/Info.plist').read_bytes())
        self.binary = self.app / 'Contents/MacOS' / self.info['CFBundleExecutable']
        self.suite = BUNDLE + '.' + uuid.uuid4().hex
        self.env = dict(os.environ, APP_LIFECYCLE_SUPPORT_DIR=str(self.root / 'support'), APP_LIFECYCLE_CLOUD_DIR=str(self.root / 'cloud'),
                        DOCKIT_LIFECYCLE_SUITE=self.suite)
        self.env.pop('APP_LIFECYCLE_FOLLOW_CHANNEL', None)  # isolated and no channel: no running app is signalled
        self.addCleanup(forget, self.suite)

    def run_words(self, *words, prefix=()):
        return subprocess.run([*prefix, str(self.binary), *words], env=self.env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=90)

    def test_the_bundle_answers_read_commands_about_itself(self):
        status = self.run_words('status', '--json')
        body = json.loads(status.stdout)
        self.assertEqual((status.returncode, body['ok'], body['command']), (0, True, 'status'))
        self.assertEqual((body['app']['version'], body['app']['build'], body['app']['bundle_id']),
                         (self.info['CFBundleShortVersionString'], self.info['CFBundleVersion'], self.info['CFBundleIdentifier']))
        # The words a wrapper may forward to this bundle are declared in its Info.plist.
        self.assertEqual(sorted(self.info['DocKitCommandVerbs']), ['config', 'help', 'settings', 'status', 'update'])
        self.assertEqual((body['engine']['ready'], body['engine']['operations'], body['settings']),
                         (True, 9, {'last_operation': None, 'target_formats': {}}))
        config = json.loads(self.run_words('config', 'status', '--json').stdout)
        self.assertEqual((config['ok'], config['command'], config['has_settings'], config['sync_enabled']), (True, 'config status', True, False))
        # The sentence under the switch: the temporary support directory holds no sync record, so it is the
        # initial one for the switch (live when your own copy of the app happens to be running).
        self.assertEqual(config['sync_status'], {'text': OFF, 'at': None, 'from': 'derived', 'live': config['app_running']})
        wrong = self.run_words('config', 'status', '--no-such', '--json')
        self.assertEqual((wrong.returncode, json.loads(wrong.stdout)['error']['code']), (2, 'usage'))
        wrong = self.run_words('status', '--no-such', '--json')
        self.assertEqual((wrong.returncode, json.loads(wrong.stdout)['error']['code']), (2, 'usage'))
        wrong = self.run_words('update', 'install', '--no-such', '--json')   # refused on the words alone: no lookup, no replacement
        self.assertEqual((wrong.returncode, json.loads(wrong.stdout)['error']['code']), (2, 'usage'))
        top = self.run_words('help')
        self.assertEqual(top.returncode, 0)
        for line in ('  status ', '  settings ', '  config status ', '  update check ', '  config export ', '  config import ',
                     '  config sync ', '  update install --yes '):
            self.assertIn('\n' + line, top.stdout)
        self.assertNotIn('暂无命令', top.stdout)
        if SANDBOX.exists():
            check = self.run_words('update', 'check', '--json', prefix=(str(SANDBOX), '-p', NO_NETWORK))
            body = json.loads(check.stdout)
            self.assertEqual((check.returncode, body['error']['code'], body['current']),
                             (1, 'check_incomplete', {'version': self.info['CFBundleShortVersionString'], 'build': self.info['CFBundleVersion']}))
            # No release record can be read: the upgrade command stops there, before any confirmation or replacement.
            install = self.run_words('update', 'install', '--yes', '--json', prefix=(str(SANDBOX), '-p', NO_NETWORK))
            body = json.loads(install.stdout)
            self.assertEqual((install.returncode, body['command'], body['error']['code']), (1, 'update install', 'check_incomplete'))
        self.assertFalse((self.root / 'support').exists() or (self.root / 'cloud').exists())


if __name__ == '__main__':
    unittest.main()
