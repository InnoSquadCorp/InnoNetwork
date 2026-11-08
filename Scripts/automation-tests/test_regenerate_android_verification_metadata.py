"""The human-run regeneration script stops its Gradle daemon and keeps its own exit status."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Scripts/regenerate_android_verification_metadata.sh'

# Stands in for gradlew. A build leaves a "daemon" that keeps adding files to
# GRADLE_USER_HOME, as the real one does with logs and caches, until --stop.
GRADLEW = r'''#!/usr/bin/env bash
set -euo pipefail
echo "$GRADLE_USER_HOME|$*" >> "$FAKE_LOG"
pids="$GRADLE_USER_HOME/daemon/pids"
if [[ " $* " == *" --stop "* ]]; then
    while read -r pid; do
        kill "$pid" 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
    done < "$pids"
    exit 0
fi
mkdir -p "$GRADLE_USER_HOME/daemon/9.8.2"
if [[ ! -f "$pids" ]]; then
    (
        set +e
        logs="$GRADLE_USER_HOME/daemon/9.8.2"
        i=0
        while :; do
            i=$(((i + 1) % 8))
            [[ -d "$logs" ]] || mkdir -p "$logs" 2>/dev/null
            : > "$logs/daemon.$i.out.log" 2>/dev/null
        done
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" >> "$pids"
    echo "$!" >> "$FAKE_PIDS"
fi
if [[ -n "${FAKE_LOCK:-}" ]]; then
    mkdir -p "$GRADLE_USER_HOME/locked/entry"
    chmod 500 "$GRADLE_USER_HOME/locked"
fi
if [[ -n "${FAKE_FAIL:-}" && "$*" == *"$FAKE_FAIL"* ]]; then
    exit "$FAKE_FAIL_STATUS"
fi
'''

HELPER = '''import os
import sys
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(f'helper {sys.argv[1]}\\n')
if sys.argv[1] == os.environ.get('FAKE_HELPER_FAIL'):
    sys.exit(int(os.environ['FAKE_HELPER_STATUS']))
'''

JAVA = '#!/usr/bin/env bash\necho \'openjdk version "17.0.12" 2024-07-16\' >&2\n'


class RegenerateAndroidVerificationMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(self.clean)
        self.repo = self.tmp / 'repo'
        self.write(self.repo / 'Scripts/regenerate_android_verification_metadata.sh', SCRIPT.read_text())
        self.write(self.repo / 'Scripts/check_android_wrapper_integrity.sh', '#!/usr/bin/env bash\n')
        self.write(self.repo / 'Scripts/android_verification_metadata.py', HELPER)
        self.write(self.repo / 'Platforms/Android/gradlew', GRADLEW)
        self.write(self.tmp / 'jdk/bin/java', JAVA)
        (self.tmp / 'tmp').mkdir()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def clean(self):
        for pid in self.pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for path in self.tmp.rglob('locked'):
            path.chmod(0o700)
        shutil.rmtree(self.tmp)

    def pids(self):
        path = self.tmp / 'pids'
        return [int(line) for line in path.read_text().split()] if path.exists() else []

    def live_daemons(self):
        live = []
        for pid in self.pids():
            try:
                os.kill(pid, 0)
                live.append(pid)
            except ProcessLookupError:
                pass
        return live

    def run_script(self, **extra):
        env = dict(os.environ, JAVA_HOME=str(self.tmp / 'jdk'), TMPDIR=str(self.tmp / 'tmp'),
                   FAKE_LOG=str(self.tmp / 'log'), FAKE_PIDS=str(self.tmp / 'pids'), **extra)
        env.pop('GRADLE_USER_HOME', None)
        result = subprocess.run(['bash', str(self.repo / 'Scripts/regenerate_android_verification_metadata.sh')],
                                env=env, capture_output=True, text=True, timeout=60)
        log = (self.tmp / 'log').read_text().splitlines()
        return result, log, [line.split('|', 1) for line in log if '|' in line]

    def assert_cleaned_up(self):
        self.assertEqual(self.live_daemons(), [])
        self.assertEqual(list((self.tmp / 'tmp').iterdir()), [])

    def test_success_stops_the_daemon_in_the_temporary_home_and_exits_zero(self):
        result, log, gradle = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Regenerated Android verification metadata with JDK 17.', result.stdout)
        self.assertEqual(log[-3:-1], ['helper add-aapt2-platforms', 'helper check'])
        homes = {home for home, _ in gradle}
        self.assertEqual(len(homes), 1)
        self.assertTrue(next(iter(homes)).startswith(f'{self.tmp / "tmp"}/innonetwork-gradle-home.'))
        self.assertEqual(gradle[-1][1], f'-p {self.repo / "Platforms/Android"} --stop --quiet')
        self.assertEqual(len(self.pids()), 1)
        self.assert_cleaned_up()

    def test_failed_build_keeps_its_status_and_still_stops_the_daemon(self):
        result, log, gradle = self.run_script(FAKE_FAIL='AndroidConsumer', FAKE_FAIL_STATUS='3')
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn('helper add-aapt2-platforms', log)
        self.assertTrue(gradle[-1][1].endswith('--stop --quiet'))
        self.assert_cleaned_up()

    def test_failure_before_any_build_does_not_start_gradle_to_stop_nothing(self):
        result, log, gradle = self.run_script(FAKE_HELPER_FAIL='clear', FAKE_HELPER_STATUS='4')
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(log, ['helper clear'])
        self.assertEqual(gradle, [])
        self.assert_cleaned_up()

    @unittest.skipIf(os.geteuid() == 0, 'root ignores directory permissions')
    def test_unremovable_home_after_success_only_warns(self):
        result, _, _ = self.run_script(FAKE_LOCK='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Warning: could not remove', result.stderr)
        self.assertEqual(self.live_daemons(), [])


if __name__ == '__main__':
    unittest.main()
