"""Fail-closed changed-path planner, real git deletes/renames and aggregate controls."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_policy', ROOT / 'Scripts/ci-policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def event(author='contributor', labels=(), action='opened'):
    return {'changes': {'base': {'ref': {'from': 'develop'}}} if action == 'edited' else {}, 'action': action, 'pull_request': {'user': {'login': author}, 'labels': [{'name': x} for x in labels]}}


def results(plan):
    return {'ci-plan': {'result': 'success'}, **{j: {'result': 'success' if v else 'skipped'} for j, v in plan['jobs'].items()}}


# Changed files of PR #177 (AGP 9.5.0 / Kotlin 2.4.21 / Gradle 9.8.2 human replacement).
ANDROID_177 = [
    'Platforms/Android/gradle/libs.versions.toml', 'Platforms/Android/gradle/verification-metadata.xml',
    'Platforms/Android/gradle/wrapper/gradle-wrapper.jar', 'Platforms/Android/gradle/wrapper/gradle-wrapper.properties',
    'Platforms/Android/gradlew', 'Platforms/Android/gradlew.bat', 'Platforms/Android/innonetwork-client/build.gradle.kts',
    'Platforms/Android/innonetwork-kotlinx-serialization/build.gradle.kts', 'Platforms/Android/innonetwork-ksp/build.gradle.kts',
    'Platforms/Android/innonetwork-ksp/src/main/kotlin/com/innosquad/innonetwork/ksp/InnoNetworkSymbolProcessor.kt',
    'Platforms/Android/innonetwork/build.gradle.kts', 'Scripts/check_android_wrapper_integrity.sh',
    'SmokeTests/AndroidConsumer/build.gradle.kts', 'SmokeTests/AndroidConsumer/gradle/verification-metadata.xml',
]
WEB = [
    'Platforms/Web/package.json', 'Platforms/Web/package-lock.json', 'Platforms/Web/src/session.ts',
    'Platforms/Web/api/public.d.ts', 'SmokeTests/WebConsumer/package-lock.json', 'SmokeTests/ReactConsumer/src/App.tsx',
    'SmokeTests/WebTarballConsumer/package.json', 'SmokeTests/BrowserConsumer/index.html', 'Scripts/check_web_public_api.sh',
]
# Manifests and lockfiles a grouped Dependabot npm update can change.
NPM_DEPENDABOT = [directory + '/' + name for directory in (
    'Platforms/Web', 'SmokeTests/WebConsumer', 'SmokeTests/WebTarballConsumer', 'SmokeTests/ReactConsumer')
    for name in ('package.json', 'package-lock.json')]
GRADLE_DEPENDABOT = ['Platforms/Android/gradle/libs.versions.toml', 'SmokeTests/AndroidConsumer/build.gradle.kts']


def workflow_jobs(name):
    jobs, current = {}, None
    for line in (ROOT / '.github/workflows' / name).read_text().split('\njobs:\n', 1)[1].splitlines():
        match = re.fullmatch(r'  ([a-z][a-z0-9-]*):', line)
        if match:
            current = match.group(1)
            jobs[current] = []
        elif current:
            jobs[current].append(line)
    return {job: '\n'.join(lines) for job, lines in jobs.items()}


def cross_platform_pr_paths():
    lines = (ROOT / '.github/workflows/cross-platform.yml').read_text().splitlines()
    start = lines.index('  pull_request:')
    if lines[start + 1] != '    paths:':
        raise AssertionError('cross-platform.yml pull_request must be path filtered')
    patterns = []
    for line in lines[start + 2:]:
        match = re.fullmatch(r'      - "([^"]+)"', line)
        if not match:
            break
        patterns.append(match.group(1))
    return patterns


def glob_matches(pattern, path):
    # GitHub path filters: `**` crosses directories, `*` stays inside one.
    regex = re.escape(pattern).replace(r'\*\*', '.*').replace(r'\*', '[^/]*')
    return re.fullmatch(regex, path) is not None


class PlannerTests(unittest.TestCase):
    def test_metadata_edit_rejected_and_reserved_labels_case_insensitive(self):
        edited=event(action='edited');edited.pop('changes')
        with self.assertRaisesRegex(ValueError, 'metadata-only'):
            p.make_plan('pull_request', edited, ['README.md'])
        self.assertTrue(all(p.make_plan('pull_request', event(labels=['RELEASE-VALIDATION']), ['README.md'])['jobs'].values()))
        self.assertTrue(p.make_plan('pull_request', event(labels=['CONCURRENCY-REVIEW']), ['README.md'])['jobs']['thread-sanitizer'])

    def test_source_test_example_paths_keep_every_gate(self):
        for path in ['Sources/InnoNetwork/RequestExecutor.swift', 'Sources/README.md', 'Tests/README.md',
                     'Examples/CoreSmoke/Package.swift', 'SmokeTests/README.md', 'Benchmarks/README.md',
                     'Tools/openapi-to-innonetwork/Package.swift', 'Package.swift', 'Package.resolved',
                     'Scripts/format.sh', 'unknown.file', 'docs/public-docc-products.txt']:
            plan = p.make_plan('pull_request', event(), [path])
            self.assertTrue(all(plan['jobs'].values()), path)
            p.evaluate(plan, results(plan))
            for name in p.JOBS:
                broken = copy.deepcopy(plan)
                broken['jobs'][name] = False
                with self.assertRaises(ValueError): p.evaluate(broken, results(broken))

    def test_selective_docs_and_individual_workflows(self):
        cases = {'README.md': {'documentation', 'docs-contract-sync'},
                 '.spi.yml': {'documentation', 'docs-contract-sync'},
                 '.github/workflows/codeql.yml': {'codeql', 'codeql-cross-platform'},
                 '.github/workflows/tsan.yml': {'thread-sanitizer'},
                 '.github/workflows/benchmarks.yml': {'benchmarks', 'benchmark-smoke'},
                 '.github/workflows/dependabot-auto-merge.yml': set(),
                 '.github/dependabot.yml': set()}
        for path, expected in cases.items():
            plan = p.make_plan('pull_request', event(), [path])
            self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected | {'policy'})
            p.evaluate(plan, results(plan))

    def test_codeql_uploads_every_main_configuration_or_none(self):
        # A PR that uploads only some main CodeQL configurations gets a
        # neutral GitHub CodeQL check, which blocks the Dependabot coordinator.
        paths = ['README.md', 'docs/site/index.html', 'Sources/InnoNetwork/A.swift', 'Platforms/Web/src/a.ts',
                 '.coderabbit.yaml', '.github/dependabot.yml'] + ['.github/workflows/' + n for n in p.WORKFLOW_IMPACT]
        for path in paths:
            plan = p.make_plan('pull_request', event(), [path])
            self.assertEqual(plan['jobs']['codeql'], plan['jobs']['codeql-cross-platform'], path)

    def test_android_and_web_only_changes_skip_apple_jobs(self):
        platform = set(p.PLATFORM_JOBS) | {'policy'}
        docs = {'documentation', 'docs-contract-sync'}
        cases = {'android (#177)': (ANDROID_177, platform), 'web': (WEB, platform),
                 'android and web': (ANDROID_177 + WEB, platform),
                 'android with README': (ANDROID_177 + ['Platforms/Android/README.md'], platform | docs)}
        for name, (paths, expected) in cases.items():
            plan = p.make_plan('pull_request', event(), paths)
            self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected, name)
            self.assertFalse(plan['jobs']['benchmarks'], name)
            self.assertFalse(plan['jobs']['build-and-test'], name)
            p.evaluate(plan, results(plan))
            for job in expected:
                broken = copy.deepcopy(plan)
                broken['jobs'][job] = False
                with self.assertRaises(ValueError): p.evaluate(broken, results(broken))
        for path in ANDROID_177 + WEB:
            self.assertEqual(p.path_impact(path), (set(p.PLATFORM_JOBS), 'Android/Web native package outside SwiftPM'), path)

    def test_platform_changes_mixed_with_swift_shared_or_unproven_paths_stay_full(self):
        for extra in ['Sources/InnoNetwork/RequestExecutor.swift', 'Tests/InnoNetworkTests/A.swift', 'Package.swift',
                      'Package.resolved', 'Scripts/format.sh', 'Scripts/android_verification_metadata.py',
                      'SmokeTests/InnoNetworkDocSmoke/main.swift', 'Examples/CoreSmoke/Package.swift',
                      '.github/workflows/ci.yml', '.github/actions/swiftpm-cache/action.yml', 'unknown.file',
                      '__full_change_fallback__', '__diff_unavailable_full_fallback__', 'Platforms/RELEASING.md']:
            for platform in ('Platforms/Android/gradle/libs.versions.toml', 'Platforms/Web/package-lock.json'):
                plan = p.make_plan('pull_request', event(), [platform, extra])
                self.assertTrue(all(plan['jobs'].values()), (platform, extra))
                p.evaluate(plan, results(plan))
        # Lookalike roots, other platforms, unlisted scripts and consumer Markdown are not platform evidence.
        for path in ['Platforms/AndroidTV/build.gradle.kts', 'Platforms/Webkit/a.ts', 'Platforms/iOS/a.swift',
                     'Platforms/build.gradle.kts', 'SmokeTests/AndroidConsumerX/a.kts', 'SmokeTests/WebConsumer.swift',
                     'SmokeTests/AndroidConsumer/README.md', 'Scripts/check_android_new.sh',
                     'Scripts/regenerate_android_verification_metadata.sh']:
            self.assertTrue(all(p.make_plan('pull_request', event(), [path])['jobs'].values()), path)
        for author, labels in [('dependabot[bot]', ['release-validation']), ('dependabot[bot]', ['concurrency-review']),
                               ('contributor', ['release-validation'])]:
            self.assertTrue(all(p.make_plan('pull_request', event(author, labels), ANDROID_177 + WEB)['jobs'].values()))
        for name, data in [('push', {'ref': 'refs/heads/main'}), ('merge_group', {'action': 'checks_requested'})]:
            plan = p.make_plan(name, data, ANDROID_177)
            self.assertEqual({j for j, v in plan['jobs'].items() if not v}, {'dependency-review'})

    def test_platform_lane_inputs_stay_outside_swiftpm_and_apple_jobs(self):
        # Xcode SDK directories such as Developer/Platforms/MacOSX.platform are not repository paths.
        names = [t.rstrip('/').rsplit('/', 1)[1] for t in p.PLATFORM_TREES if t.startswith('SmokeTests/')]
        names += sorted(Path(script).name for script in p.PLATFORM_SCRIPTS)
        marker = re.compile(r'Platforms/(?![A-Za-z]+\.platform\b)|' + '|'.join(map(re.escape, names)))
        def mentions(text):
            return sorted(set(marker.findall(text)))
        def file_mentions(path):
            return mentions(path.read_bytes().decode('utf-8', errors='replace'))
        self.assertEqual(file_mentions(ROOT / 'Package.swift'), [])
        jobs = workflow_jobs('ci.yml')
        self.assertEqual(set(jobs), set(p.JOBS) | {'ci-plan', 'ci-required'})
        for job, text in jobs.items():
            if job not in p.PLATFORM_JOBS | {'ci-plan', 'policy', 'ci-required'}:
                self.assertEqual(mentions(text), [], job)
        self.assertNotEqual(mentions(jobs['codeql-cross-platform']), [])
        for path in [ROOT / '.github/workflows/release-validation.yml', *sorted((ROOT / '.github/actions').rglob('*'))]:
            if path.is_file():
                self.assertEqual(file_mentions(path), [], path)
        # Other readers run only in the always-selected plan/policy jobs or in no CI job.
        readers = set(p.PLATFORM_SCRIPTS) | {'Scripts/ci-policy.py', 'Scripts/check-public-operations.py',
                                             'Scripts/regenerate_android_verification_metadata.sh'}
        for path in sorted((ROOT / 'Scripts').rglob('*')):
            relative = path.relative_to(ROOT).as_posix()
            if path.is_file() and not relative.startswith('Scripts/automation-tests/') and relative not in readers:
                self.assertEqual(file_mentions(path), [], relative)
        # Narrowing CI never leaves a platform change without its build/test workflow.
        patterns = cross_platform_pr_paths()
        for path in [tree + 'sample.kts' for tree in p.PLATFORM_TREES] + sorted(p.PLATFORM_SCRIPTS):
            self.assertTrue(any(glob_matches(pattern, path) for pattern in patterns), path)
        for script in p.PLATFORM_SCRIPTS:
            self.assertTrue((ROOT / script).is_file(), script)

    def test_dependabot_android_web_only_updates_skip_apple_jobs(self):
        platform = set(p.PLATFORM_JOBS) | {'policy'}
        for name, paths in [('npm', NPM_DEPENDABOT), ('one directory', NPM_DEPENDABOT[:2]), ('gradle', GRADLE_DEPENDABOT)]:
            for action in sorted(p.PR_ACTIONS - {'edited'}):
                plan = p.make_plan('pull_request', event('dependabot[bot]', ['dependencies', 'web'], action), paths)
                self.assertEqual(plan['lane'], 'fast', name)
                self.assertEqual({j for j, v in plan['jobs'].items() if v}, platform, name)
                self.assertFalse(plan['jobs']['benchmarks'], name)
                self.assertFalse(plan['jobs']['release-candidate'], name)
                p.evaluate(plan, results(plan))
            self.assertTrue(p.dependabot_platform_lane({'dependencies', 'web'}, paths), name)
        # Labels, shared paths, Markdown, deletion/rename sentinels and missing evidence keep the full lane.
        for labels, paths in [(['release-validation'], NPM_DEPENDABOT), (['RELEASE-VALIDATION'], NPM_DEPENDABOT),
                              (['concurrency-review'], NPM_DEPENDABOT), ([], NPM_DEPENDABOT + ['Package.resolved']),
                              ([], NPM_DEPENDABOT + ['Platforms/Web/README.md']), ([], NPM_DEPENDABOT + ['__full_change_fallback__']),
                              ([], ['__diff_unavailable_full_fallback__']), ([], [])]:
            plan = p.make_plan('pull_request', event('dependabot[bot]', labels), paths)
            self.assertEqual(plan['lane'], 'release-validation', (labels, paths))
            self.assertTrue(all(plan['jobs'].values()), (labels, paths))
            self.assertFalse(p.dependabot_platform_lane(set(labels), paths), (labels, paths))
        plan = p.make_plan('pull_request', event('dependabot[bot]', [], 'edited'), NPM_DEPENDABOT)
        self.assertEqual(plan['lane'], 'fast')

    def test_dependabot_platform_directories_are_platform_trees(self):
        # Every Dependabot npm/Gradle directory must stay inside the Android/Web
        # trees; otherwise its updates would never reach the narrowed lane.
        config = json.loads((ROOT / '.github/dependabot.yml').read_text())
        for update in config['updates']:
            if update['package-ecosystem'] in ('npm', 'gradle'):
                for directory in update['directories']:
                    self.assertIn(directory.lstrip('/') + '/', p.PLATFORM_TREES, directory)

    def test_all_bot_majors_toolchains_and_labels_require_full(self):
        for action in p.PR_ACTIONS:
            for author, labels in [('dependabot[bot]', []), ('contributor', ['release-validation'])]:
                plan = p.make_plan('pull_request', event(author, labels, action), ['.github/dependabot.yml'])
                self.assertTrue(all(plan['jobs'].values()))
                self.assertEqual(plan['lane'], 'release-validation')
        plan = p.make_plan('pull_request', event(labels=['concurrency-review']), ['LICENSE'])
        self.assertTrue(plan['jobs']['thread-sanitizer'])
        self.assertFalse(plan['jobs']['lint'])

    def test_main_dispatch_queue_full_except_pr_only_dependency_review(self):
        for name, data in [('push', {'ref': 'refs/heads/main'}), ('workflow_dispatch', {}),
                           ('merge_group', {'action': 'checks_requested'})]:
            plan = p.make_plan(name, data, [])
            self.assertEqual({j for j, v in plan['jobs'].items() if not v}, {'dependency-review'})
            p.evaluate(plan, results(plan))
        self.assertTrue(all(p.make_plan('pull_request', event(), [])['jobs'].values()))

    def test_selected_failures_and_unselected_success_are_not_accepted(self):
        plan = p.make_plan('pull_request', event(), ['README.md'])
        for job in ['ci-plan'] + list(p.JOBS):
            for value in ['failure', 'cancelled', 'neutral', None, 'skipped', 'success']:
                needs = results(plan)
                original = needs[job]['result']
                needs[job]['result'] = value
                if value != original:
                    with self.assertRaises(ValueError): p.evaluate(plan, needs)
        for job in results(plan):
            needs = results(plan); needs.pop(job)
            with self.assertRaises(ValueError): p.evaluate(plan, needs)
        with self.assertRaises(ValueError): p.evaluate(plan, dict(results(plan), surprise={'result': 'success'}))

    def test_malformed_policy_and_event_fail_closed(self):
        for path in ['', '/root', '../README.md', 'a/../b', 'a//b', 'a\\b', 'a\nb']:
            with self.assertRaises(ValueError): p.path_impact(path)
        for name, data in [('pull_request', {}), ('push', {'ref': 'refs/heads/topic'}),
                           ('merge_group', {'action': 'closed'}), ('unknown', {})]:
            with self.assertRaises(ValueError): p.make_plan(name, data, ['README.md'])
        with self.assertRaises(ValueError): p.load_json('{"a": 1, "a": 2}')
        for key, value in [('jobs', {}), ('schema', True), ('lane', 'fake'), ('event', 'fake')]:
            plan = p.make_plan('pull_request', event(), ['README.md']); plan[key] = value
            with self.assertRaises(ValueError): p.evaluate(plan, {})

    def test_git_stream_malformed_or_failed_is_rejected(self):
        for data in [b'M\0README.md', b'R100\0old.md\0', b'U\0README.md\0', b'R200\0a\0b\0', b'M\0\xff\0']:
            with mock.patch.object(p.subprocess, 'check_output', return_value=data):
                with self.assertRaises((ValueError, UnicodeError)): p.changed_paths(ROOT, 'a'*40, 'b'*40)
        with self.assertRaises(ValueError): p.changed_paths(ROOT, 'main', 'b'*40)

    def test_edited_base_retarget_replans_the_new_base_diff(self):
        # The same head is docs-only against its old base but includes source
        # changes against main. A retarget must not retain that old narrow plan.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', '-C', tmp, *args], text=True).strip()
            git('init', '-q'); git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Test')
            (root / 'README.md').write_text('base\n')
            git('add', '.'); git('commit', '-qm', 'main'); main = git('rev-parse', 'HEAD')
            (root / 'Sources').mkdir(); (root / 'Sources/Retarget.swift').write_text('struct Retarget {}\n')
            git('add', '.'); git('commit', '-qm', 'old base'); old_base = git('rev-parse', 'HEAD')
            (root / 'README.md').write_text('head docs\n')
            git('add', '.'); git('commit', '-qm', 'head'); head = git('rev-parse', 'HEAD')
            old = p.make_plan('pull_request', event(), p.changed_paths(root, old_base, head))
            self.assertFalse(old['jobs']['build-and-test'])
            retarget = event(action='edited')
            retarget['changes'] = {'base': {'ref': {'from': 'integration'}}}
            retarget['pull_request'].update(base={'sha':main}, head={'sha':head})
            paths = p.changed_paths(root, retarget['pull_request']['base']['sha'], head)
            self.assertIn('Sources/Retarget.swift', paths)
            current = p.make_plan('pull_request', retarget, paths)
            self.assertTrue(all(current['jobs'].values()))
            p.evaluate(current, results(current))
            with self.assertRaises(ValueError):
                p.evaluate(current, results(old))

    def test_real_git_deletion_and_both_rename_sides_force_full(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', '-C', tmp, *args], text=True).strip()
            git('init', '-q'); git('config', 'user.email', 'test@example.invalid'); git('config', 'user.name', 'Test')
            (root/'old.md').write_text('old\n'); (root/'delete.md').write_text('gone\n')
            git('add', '.'); git('commit', '-qm', 'base'); base = git('rev-parse', 'HEAD')
            git('mv', 'old.md', 'renamed.md'); (root/'delete.md').unlink()
            git('add', '-u'); git('commit', '-qm', 'rename and delete'); head = git('rev-parse', 'HEAD')
            paths = p.changed_paths(root, base, head)
            self.assertTrue({'old.md', 'renamed.md', 'delete.md'} <= set(paths))
            self.assertTrue(all(p.make_plan('pull_request', event(), paths)['jobs'].values()))


if __name__ == '__main__': unittest.main()
