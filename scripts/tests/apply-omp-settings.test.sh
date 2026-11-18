#!/usr/bin/env bash
# Run: ./scripts/tests/apply-omp-settings.test.sh (Python 3 only; no installed omp).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 - "$@" "$ROOT" <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop())
FAKE = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
p = Path(os.environ['PI_CODING_AGENT_DIR'])
profile = os.environ.get('OMP_PROFILE') or os.environ.get('PI_PROFILE')
if profile and profile != 'default':
    p = Path(os.environ['HOME']) / '.omp/profiles' / profile / 'agent'
p.mkdir(parents=True, exist_ok=True)
(p / 'agent.db').write_text('read writes DB\n')
if os.environ.get('PI_CONFIG_FILES'):
    sys.exit('PI_CONFIG_FILES was not cleared')
if (Path.cwd() / '.omp').exists():
    sys.exit('project configuration was not isolated')
a = sys.argv[1:]
if a == ['config', 'path']:
    print(p)
    sys.exit()
try:
    data = json.loads((p / 'config.yml').read_text())
except Exception:
    sys.exit('malformed config')
def flat(d, prefix=''):
    out = {}
    for k, v in d.items():
        key = prefix + k
        if isinstance(v, dict) and key != 'task.agentCompactionThresholdOverrides':
            out.update(flat(v, key + '.'))
        else:
            out[key] = {'value': v, 'type': 'fixture', 'description': 'fixture'}
    return out
values = flat(data)
defaults = {'compaction.thresholdTokens': -1, 'compaction.idleEnabled': False,
 'compaction.idleThresholdTokens': 50000, 'compaction.idleTimeoutSeconds': 600,
 'tools.artifactSpillThreshold': 20, 'tools.artifactTailLines': 100,
 'task.agentCompactionThresholdOverrides': {}, 'retry.fallbackOn': 'never',
 'retry.usageAwareFallback': False}
mode = os.environ.get('FAKE_MODE', '')
target = Path(os.environ.get('FAKE_TARGET', str(p / 'config.yml')))
if mode == 'change-during-capture':
    marker = Path(os.environ['FAKE_CONTROL'])
    if not marker.exists():
        target.write_bytes(target.read_bytes() + b'\n')
        marker.touch()
rollback_readback = (mode.startswith('rollback-') and
                     target.read_bytes() == Path(os.environ['FAKE_BACKUP']).read_bytes())
if rollback_readback and mode == 'rollback-global-mismatch':
    values['compaction.thresholdTokens']['value'] += 1
if a == ['config', 'list', '--scope', 'global', '--json']:
    if mode == 'bad-list':
        print('{bad')
    else:
        print(json.dumps(values))
elif len(a) == 4 and a[:2] == ['config', 'get'] and a[3] == '--json':
    key = a[2]
    if data.get('compaction', {}).get('idleEnabled') is True and key == 'compaction.thresholdTokens':
        if mode == 'bad-read':
            print('{bad'); sys.exit()
        if mode == 'missing-read':
            print(json.dumps({'key': key})); sys.exit()
        if mode == 'failed-read':
            sys.exit('failed read')
    value = values.get(key, {'value': defaults[key]})['value']
    if rollback_readback and mode == 'rollback-effective-mismatch' and key == 'compaction.thresholdTokens':
        value += 1
    print(json.dumps({'key': key, 'value': value, 'type': 'fixture', 'description': ''}))
elif len(a) == 4 and a[:2] == ['config', 'set']:
    key, value = a[2], json.loads(a[3])
    (p / '.fake-set').write_text('set')
    if os.environ.get('FAKE_STARTED'):
        Path(os.environ['FAKE_STARTED']).touch()
        time.sleep(0.3)
    if mode == 'failed-write' and key == 'compaction.idleEnabled':
        sys.exit('failed write')
    if not (mode == 'ignore-write' and key == 'compaction.thresholdTokens'):
        node = data
        parts = key.split('.')
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = value
        (p / 'config.yml').write_text(json.dumps(data, indent=2) + '\n')
else:
    sys.exit('unexpected fake omp invocation: ' + repr(a))
'''

class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        (self.repo / 'hosts/rhdevvps').mkdir(parents=True)
        self.script = self.repo / 'scripts/apply-omp-settings'
        self.assertTrue((ROOT / 'scripts/apply-omp-settings').is_file(),
                        'production entrypoint is missing (expected RED before implementation)')
        shutil.copy2(ROOT / 'scripts/apply-omp-settings', self.script)
        self.manifest = self.repo / 'hosts/rhdevvps/omp-settings.json'
        shutil.copy2(ROOT / 'hosts/rhdevvps/omp-settings.json', self.manifest)
        self.wanted = json.loads(self.manifest.read_text())
        self.home = self.base / 'home'
        self.agent = self.home / '.omp/agent'
        self.agent.mkdir(parents=True)
        self.config = self.agent / 'config.yml'
        self.original_data = {
            'compaction': {'thresholdTokens': 90000, 'idleEnabled': False, 'custom': 7},
            'modelRoles': {'default': 'SECRET-MODEL'},
            'retry': {'fallbackChains': {'default': ['SECRET-CHAIN']}, 'custom': 42},
            'task': {'agentAccountPools': {'reviewer': ['SECRET-POOL']},
                     'custom': 'keep', 'agentCompactionThresholdOverrides': {'custom-reviewer': 55555}},
            'tools': {'custom': 'keep'}}
        self.original = (json.dumps(self.original_data, indent=3) + '\n').encode()
        self.config.write_bytes(self.original)
        self.config.chmod(0o600)
        (self.agent / 'agent.db').write_bytes(b'original db\x00')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        (self.bin / 'omp').write_text(FAKE)
        (self.bin / 'omp').chmod(0o755)
        self.cwd = self.base / 'project'
        (self.cwd / '.omp').mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), PI_CODING_AGENT_DIR=str(self.agent),
                        PI_CONFIG_FILES='/secret/overlay.yml', PATH=str(self.bin) + os.pathsep + os.environ['PATH'])
        self.env['FAKE_TARGET'] = str(self.config)
        self.env['FAKE_CONTROL'] = str(self.base / 'capture-changed')
        self.env.pop('FAKE_MODE', None)
        self.env.pop('FAKE_STARTED', None)

    def run_entry(self, *args, success=True, **env):
        result = subprocess.run([str(self.script), *map(str, args)], cwd=self.cwd,
                                env=dict(self.env, **env), text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {str(p.relative_to(self.agent)): (stat.S_IMODE(p.lstat().st_mode),
                p.read_bytes() if p.is_file() else None) for p in self.agent.rglob('*')
                if p.name != '.apply-omp-settings.lock'}

    def backups(self):
        return sorted(self.agent.glob('config.yml.bak-*'))

    def assert_applied(self):
        data = json.loads(self.config.read_text())
        expected = copy.deepcopy(self.original_data)
        for key, value in self.wanted.items():
            parts = key.split('.')
            node = expected
            for part in parts[:-1]:
                node = node.setdefault(part, {})
            if key == 'task.agentCompactionThresholdOverrides':
                node[parts[-1]].update(value)
            else:
                node[parts[-1]] = value
        self.assertEqual(data, expected)

    def test_dry_run_diff_and_zero_target_mutation(self):
        self.assertFalse((self.agent / '.apply-omp-settings.lock').exists())
        before = self.snapshot()
        r = self.run_entry('--dry-run')
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.agent / '.apply-omp-settings.lock').exists())
        self.assertIn('compaction.thresholdTokens', r.stdout)
        self.assertIn('90000', r.stdout)
        self.assertIn('120000', r.stdout)
        self.assertIn('retry.usageAwareFallback', r.stdout)
        self.assertNotIn('custom-reviewer', r.stdout)
        for secret in ('SECRET-MODEL', 'SECRET-CHAIN', 'SECRET-POOL'):
            self.assertNotIn(secret, r.stdout + r.stderr)

    def test_named_profile_environment_cannot_redirect_target(self):
        for variable in ('OMP_PROFILE', 'PI_PROFILE'):
            with self.subTest(variable=variable):
                self.config.write_bytes(self.original)
                before = self.snapshot()
                self.run_entry('--dry-run', **{variable: 'unintended'})
                self.assertEqual(before, self.snapshot())
                self.run_entry(**{variable: 'unintended'})
                self.assert_applied()

    def test_native_unset_threshold_can_be_applied_and_rolled_back(self):
        data = copy.deepcopy(self.original_data)
        del data['compaction']['thresholdTokens']
        original = (json.dumps(data, indent=3) + '\n').encode()
        self.config.write_bytes(original)
        before = self.snapshot()
        preview = self.run_entry('--dry-run')
        self.assertIn('compaction.thresholdTokens: <unset> -> 120000', preview.stdout)
        self.assertEqual(before, self.snapshot())
        self.run_entry()
        self.assert_applied()
        backup = self.backups()[0]
        self.assertEqual(backup.read_bytes(), original)
        self.run_entry('--rollback', backup)
        self.assertEqual(self.config.read_bytes(), original)

    def test_apply_preserves_unowned_values_and_is_idempotent(self):
        r = self.run_entry()
        self.assert_applied()
        self.assertIn('Before', r.stdout)
        self.assertIn('After', r.stdout)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_bytes(), self.original)
        self.assertEqual(stat.S_IMODE(self.backups()[0].stat().st_mode), 0o600)
        for secret in ('SECRET-MODEL', 'SECRET-CHAIN', 'SECRET-POOL'):
            self.assertNotIn(secret, r.stdout + r.stderr)
        first = json.loads(self.config.read_text())
        self.run_entry()
        self.assertEqual(json.loads(self.config.read_text()), first)
        self.assertEqual(len(self.backups()), 2)

    def test_rollback_restores_exact_bytes_and_backs_up_current(self):
        self.run_entry()
        backup = self.backups()[0]
        changed = self.config.read_bytes()
        self.run_entry('--rollback', backup)
        self.assertEqual(self.config.read_bytes(), self.original)
        recovery = [p for p in self.backups() if p != backup]
        self.assertEqual(len(recovery), 1)
        self.assertEqual(recovery[0].read_bytes(), changed)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_rollback_ignores_invalid_or_missing_current_config(self):
        backup = self.agent / 'config.yml.bak-original'
        backup.write_bytes(self.original)
        fractional = copy.deepcopy(self.original_data)
        fractional['tools']['artifactSpillThreshold'] = 2.5
        percentage = copy.deepcopy(self.original_data)
        percentage['task']['agentCompactionThresholdOverrides']['reviewer'] = '80%'
        for current in (json.dumps(fractional).encode(), json.dumps(percentage).encode(),
                        b'malformed current config', None):
            with self.subTest(current=current):
                if current is None:
                    self.config.unlink()
                else:
                    self.config.write_bytes(current)
                old = set(self.backups())
                result = self.run_entry('--rollback', backup)
                self.assertEqual(self.config.read_bytes(), self.original)
                recovery = set(self.backups()) - old
                self.assertEqual(len(recovery), 0 if current is None else 1)
                if recovery:
                    self.assertEqual(recovery.pop().read_bytes(), current)
                self.assertIn('Rollback verified.', result.stdout)

    def test_lock_is_private_profile_local_and_preview_skips_it(self):
        lock = self.agent / '.apply-omp-settings.lock'
        self.run_entry('--dry-run')
        self.assertFalse(lock.exists())
        self.run_entry()
        self.assertTrue(lock.is_file())
        self.assertEqual(stat.S_IMODE(lock.stat().st_mode), 0o600)

    def test_config_changed_during_preparation_is_preserved(self):
        backup = self.agent / 'config.yml.bak-original'
        backup.write_bytes(self.original)
        for args, operation in (((), 'apply'), (('--rollback', backup), 'rollback')):
            with self.subTest(operation=operation):
                self.config.write_bytes(self.original)
                Path(self.env['FAKE_CONTROL']).unlink(missing_ok=True)
                before = self.snapshot()
                expected = copy.deepcopy(before)
                mode, content = expected['config.yml']
                expected['config.yml'] = (mode, content + b'\n')
                old = set(self.backups())
                result = self.run_entry(*args, success=False, FAKE_MODE='change-during-capture')
                self.assertIn(f'Config changed while preparing {operation}', result.stderr)
                self.assertEqual(set(self.backups()), old)
                self.assertEqual(self.snapshot(), expected)

    def test_post_rollback_readback_mismatches_fail(self):
        backup = self.agent / 'config.yml.bak-original'
        backup.write_bytes(self.original)
        changed = copy.deepcopy(self.original_data)
        changed['compaction']['thresholdTokens'] = 120000
        current = json.dumps(changed).encode()
        for mode in ('rollback-global-mismatch', 'rollback-effective-mismatch'):
            with self.subTest(mode=mode):
                self.config.write_bytes(current)
                old = set(self.backups())
                result = self.run_entry('--rollback', backup, success=False,
                                        FAKE_MODE=mode, FAKE_BACKUP=str(backup))
                self.assertIn('read-back mismatch', result.stderr)
                self.assertNotIn('Rollback verified.', result.stdout)
                self.assertEqual(self.config.read_bytes(), self.original)
                recovery = set(self.backups()) - old
                self.assertEqual(len(recovery), 1)
                self.assertEqual(recovery.pop().read_bytes(), current)

    def test_readback_or_write_failures_never_report_success(self):
        for mode in ('ignore-write', 'bad-read', 'missing-read', 'failed-read', 'failed-write'):
            with self.subTest(mode=mode):
                self.config.write_bytes(self.original)
                (self.agent / '.fake-set').unlink(missing_ok=True)
                old = set(self.backups())
                self.run_entry(success=False, FAKE_MODE=mode)
                new = set(self.backups()) - old
                self.assertEqual(len(new), 1)
                self.assertEqual(new.pop().read_bytes(), self.original)

    def test_invalid_arguments_and_backups_do_not_modify_target(self):
        foreign = self.base / 'foreign.yml'
        foreign.write_bytes(self.original)
        symlink = self.agent / 'config.yml.bak-symlink'
        symlink.symlink_to(foreign)
        malformed = self.agent / 'config.yml.bak-malformed'
        malformed.write_text('not valid fixture config')
        cases = [('--what',), ('--dry-run', '--rollback', foreign), ('--rollback',),
                 ('--rollback', foreign), ('--rollback', symlink), ('--rollback', malformed),
                 ('--rollback', self.config)]
        for args in cases:
            with self.subTest(args=args):
                before = self.snapshot()
                self.run_entry(*args, success=False)
                self.assertEqual(before, self.snapshot())

    def test_rejects_unsafe_or_malformed_config_without_writes(self):
        for kind in ('missing', 'symlink', 'malformed'):
            with self.subTest(kind=kind):
                self.config.unlink(missing_ok=True)
                if kind == 'symlink':
                    source = self.base / 'source.yml'
                    source.write_bytes(self.original)
                    self.config.symlink_to(source)
                elif kind == 'malformed':
                    self.config.write_text('malformed fixture config')
                before = self.snapshot()
                self.run_entry(success=False)
                self.assertEqual(before, self.snapshot())

    def test_manifest_allowlist_types_and_duplicates_fail_closed(self):
        original_manifest = self.manifest.read_text()
        variants = []
        for key, value in [('modelRoles.default', 'forbidden'),
                           ('retry.fallbackChains', {}), ('task.agentAccountPools', {}),
                           ('compaction.thresholdTokens', True), ('compaction.idleEnabled', 1),
                           ('retry.fallbackOn', 'unsupported'),
                           ('task.agentCompactionThresholdOverrides', {'rogue-reviewer': 1})]:
            bad = json.loads(original_manifest)
            bad[key] = value
            variants.append(json.dumps(bad))
        missing = json.loads(original_manifest)
        del missing['tools.artifactTailLines']
        variants += [json.dumps(missing), '{bad', original_manifest.rstrip()[:-1] +
                     ', "compaction.thresholdTokens": 120000}']
        for content in variants:
            with self.subTest(content=content):
                self.manifest.write_text(content)
                before = self.snapshot()
                self.run_entry(success=False)
                self.assertEqual(before, self.snapshot())

    def test_bad_global_list_fails_before_backup(self):
        before = self.snapshot()
        self.run_entry(success=False, FAKE_MODE='bad-list')
        self.assertEqual(before, self.snapshot())

    def test_concurrent_invocation_is_refused(self):
        started = self.base / 'started'
        first = subprocess.Popen([str(self.script)], cwd=self.cwd,
                                 env=dict(self.env, FAKE_STARTED=str(started)),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: first.poll() is None and first.kill())
        deadline = time.monotonic() + 10
        while not started.exists() and first.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(started.exists(), 'first invocation did not reach config set')
        second = self.run_entry(success=False)
        self.assertIn('lock', (second.stdout + second.stderr).lower())
        stdout, stderr = first.communicate(timeout=15)
        self.assertEqual(first.returncode, 0, stdout + stderr)
        self.assertEqual(len(self.backups()), 1)
        self.assert_applied()

unittest.main(verbosity=2)
PY
