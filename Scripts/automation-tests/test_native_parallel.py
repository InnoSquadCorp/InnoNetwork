import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Same tests work in Tools/tests, Scripts/tests and Scripts/automation-tests.
CANDIDATES = [ROOT/'native_parallel.py', ROOT.parent/'native_parallel.py', Path(__file__).with_name('native_parallel.py')]
MODULE = next(path for path in CANDIDATES if path.is_file())
spec = importlib.util.spec_from_file_location('native_parallel_tested', MODULE)
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)

VALID = '''name: Test
on: push
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - parallel:
          - name: A
            run: echo first
          - name: B
            run: |
              echo second
              echo third
      - name: After joined checks
        run: echo done
'''

class NativeParallelTests(unittest.TestCase):
    def test_line_preserving_projection_and_join(self):
        result = p.project(VALID)
        self.assertEqual(len(result.splitlines()), len(VALID.splitlines()))
        self.assertIn('      - name: A\n        run: echo first', result)
        self.assertIn('      - name: B\n        run: |\n          echo second', result)
        self.assertTrue(result.endswith('        run: echo done\n'))
    def test_ordinary_workflow_unchanged(self):
        text = 'jobs:\n  a:\n    steps:\n      - run: echo hello\n'
        self.assertEqual(p.project(text), text)
    def test_unsupported_native_or_child_state_rejected(self):
        for replacement in ['id: a', 'if: always()', 'continue-on-error: true', 'env: {}', 'uses: org/action@v1', 'background: true', 'wait: a', 'cancel: a', 'parallel: []']:
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                p.project(VALID.replace('run: echo first', replacement))
        for value in ['echo $GITHUB_ENV', 'echo $GITHUB_OUTPUT', 'echo $GITHUB_PATH', 'echo $GITHUB_STEP_SUMMARY', 'echo "${{ steps.a.outputs.x }}"']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.project(VALID.replace('echo first', value))
    def test_single_duplicate_nested_and_wrong_shape_rejected(self):
        bad = [VALID.replace('          - name: B\n            run: |\n              echo second\n              echo third\n',''),
               VALID.replace('name: B','name: A'), VALID.replace('name: B', 'name: ${{ matrix.x }}'), VALID.replace('            run: echo first','            run: echo first\n            run: echo again'),
               VALID.replace('      - parallel:','      - parallel: []'),
               VALID.replace('          - name: B','        - name: B'),
               VALID.replace('            run: echo first','            env:\n              A: B\n            run: echo first')]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):p.project(value)
    def test_background_outside_group_rejected(self):
        with self.assertRaises(ValueError):p.project('jobs:\n  a:\n    steps:\n      - run: echo x\n        background: true\n')
    def test_ten_limit(self):
        body=''.join(f'          - name: C{i}\n            run: echo {i}\n' for i in range(11))
        with self.assertRaises(ValueError):p.project(VALID[:VALID.index('          - name: A')]+body)

if __name__ == '__main__':unittest.main()
