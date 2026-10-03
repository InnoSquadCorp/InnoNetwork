"""Exercise the changelog checker in independent source-tree fixtures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ChangelogSyncTests(unittest.TestCase):
    def check(self, notes, source="struct KnownSymbol {}\n"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            (root / 'Sources').mkdir()
            shutil.copy2(ROOT / 'Scripts/check_changelog_sync.sh', root / 'Scripts/check_changelog_sync.sh')
            (root / 'CHANGELOG.md').write_text(notes)
            (root / 'Sources/Fixture.swift').write_text(source)
            return subprocess.run(['bash', str(root / 'Scripts/check_changelog_sync.sh')],
                                  capture_output=True, text=True)

    def test_prose_only_unreleased_succeeds(self):
        result = self.check('## [Unreleased]\n### Changed\n- Improve schema validation.\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no leading symbol bullets', result.stdout)

    def test_empty_unreleased_succeeds(self):
        self.assertEqual(self.check('## [Unreleased]\n\n## [1.0.0]\n- Earlier release.\n').returncode, 0)

    def test_existing_symbol_succeeds(self):
        result = self.check('## [Unreleased]\n- `KnownSymbol` now handles cancellation.\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('all resolve', result.stdout)

    def test_missing_symbol_fails(self):
        result = self.check('## [Unreleased]\n- `MissingSymbol` supports requests.\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MissingSymbol', result.stderr)

    def test_mixed_prose_does_not_hide_missing_symbol(self):
        result = self.check('## [Unreleased]\n- Improve validation.\n- `MissingSymbol` supports requests.\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MissingSymbol', result.stderr)

    def test_removed_and_historical_symbols_are_excluded(self):
        result = self.check('## [Unreleased]\n### Removed\n- `RemovedSymbol` is gone.\n'
                            '### Changed\n- `KnownSymbol` is faster.\n## [1.0.0]\n- `HistoricalSymbol` existed.\n')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
