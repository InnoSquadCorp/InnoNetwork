#!/usr/bin/env python3
"""Offline lifecycle fixtures; all publication records here are synthetic."""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Scripts/validate_6_1_release_state.py"
SPEC = importlib.util.spec_from_file_location("minor_release_state", VALIDATOR)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MinorReleaseStateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="innonetwork-6.1-state-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.fixture("draft")

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def replace(self, path, old, new):
        original = (self.root / path).read_text(encoding="utf-8")
        self.assertIn(old, original)
        self.write(path, original.replace(old, new))

    def fixture(self, state):
        marker = "candidate" if state == "draft" else "release"
        self.write("API_STABILITY.md", f"<!-- encoded-request-{marker}: 6.1.0 -->\n"
                   + MODULE.BOUNDARIES[state] + "\n- " + MODULE.CODEC_SYMBOLS
                   + MODULE.LEDGER_SUFFIXES[state] + "\n")
        self.write("Scripts/symbols/README.md", MODULE.SYMBOL_DESCRIPTIONS[state] + "\n")
        notes = f"<!-- release-status: {'draft' if state == 'draft' else 'ready'} -->\n"
        notes += "# InnoNetwork 6.1.0\n\n" + MODULE.STATUSES[state] + "\n"
        if state == "draft":
            readme = "The 6.1 candidate on this branch is Draft and unpublished."
            changelog = "## [Unreleased]\n\n### Added — encoded request candidate (not published)\n"
        else:
            notes += "Release date: 2020-01-02\n"
            changelog = "## [Unreleased]\n\n## [6.1.0] - 2020-01-02\n\n### Added — encoded requests\n"
            if state == "ready":
                notes += "The 6.1.0 release contents are approved; readiness is not publication.\n"
                notes += "Confirm the matching tag and GitHub Release before adopting 6.1.0.\n"
                readme = "The 6.1.0 contents are Ready for release; readiness is not publication."
            else:
                url = "https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.0"
                notes += f"Published at: 2020-01-02T03:04:05Z\n{url}\n"
                readme = f"6.1.0 is published: {url}"
        self.write("README.md", readme + "\n")
        self.write("CHANGELOG.md", changelog)
        self.write("docs/releases/6.1.0.md", notes)
        releases = [{"version": "6.0.0", "publishedAt": "2020-01-01T00:00:00Z",
                     "url": "https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.0.0"}]
        if state == "published":
            releases.append({"version": "6.1.0", "publishedAt": "2020-01-02T03:04:05Z", "url": url})
        self.write("Scripts/published-releases.json", json.dumps({"releases": releases}))

    def rejected(self, message):
        with self.assertRaisesRegex((ValueError, FileNotFoundError), message):
            MODULE.validate(self.root)

    def test_all_coherent_states_and_exact_ledger_output(self):
        for state in ("draft", "ready", "published"):
            with self.subTest(state=state):
                self.fixture(state)
                self.assertEqual(MODULE.validate(self.root), state)
                result = subprocess.run(["python3", str(VALIDATOR), str(self.root), "--print-codec-ledger"],
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout.strip(), MODULE.CODEC_SYMBOLS + MODULE.LEDGER_SUFFIXES[state])

    def test_all_states_preserve_full_historical_contract_and_inventory(self):
        scope = "The previously planned 6.1 candidates are included in this 6.0 release scope."
        for state in ("draft", "ready", "published"):
            with self.subTest(state=state):
                self.fixture(state)
                additions = {
                    "API_STABILITY.md": "# API Stability (6.x)\n`6.0.0` is the approved compatibility baseline\n### Root Macro Surface (Stable in 6.0)\n",
                    "README.md": scope + '\n`6.0.0` is approved for release; readiness is not publication.\n.upToNextMajor(from: "6.0.0")\n',
                    "CHANGELOG.md": scope + "\n## [6.0.0] - 2020-01-01\n",
                    "Scripts/symbols/README.md": "## Current sizes (InnoNetwork 6.0.0 release baseline)\n| **Total** | **1,764** |\n| Stable consumer API | 367 |\n| Provisionally Stable consumer API | 1,364 |\n| `@_spi(GeneratedClientSupport)` | 33 |\n",
                }
                for path, addition in additions.items():
                    self.write(path, (self.root / path).read_text(encoding="utf-8") + "\n" + addition)
                self.write("SECURITY.md", "`6.x` becomes the supported public release line when `6.0.0` is published.\n")
                self.write("Scripts/symbols/budgets.tsv", "TOTAL\t1764\n")
                self.write("Scripts/symbols/tier-budgets.tsv", "STABLE_CONSUMER\t367\nPROVISIONAL\t1364\nSPI\t33\nTOTAL\t1764\n")
                migration = '.product(name: "InnoNetworkHLS", package: "InnoStream")\n## Stable macro-first endpoint contract\n'
                self.write("Sources/InnoNetwork/InnoNetwork.docc/MigrationTo6.md", "# Migrating to InnoNetwork 6\n" + migration)
                self.write("docs/Migration-6.0.0.md", '# Migration Guide: 6.0.0\n.upToNextMajor(from: "1.0.0")\n'
                           + "This guide describes the approved InnoNetwork 6.0 compatibility reset.\n" + migration)
                self.write("docs/ROADMAP.md", "## 6.0.0 Included Capabilities\n")
                self.write("docs/releases/6.0.0.md", "<!-- release-status: ready -->\nStatus: Ready for release\nRelease date: 2020-01-01\n"
                           + scope + "\n1,702 declarations: 307 Stable,\n1,362 Provisionally Stable, and 33 SPI.\n"
                           + "Confirm the matching tag and GitHub Release before adopting 6.0.0.\n")
                self.write("docs/releases/archive/6.1.0-superseded-roadmap.md", "<!-- release-status: draft -->\n"
                           + "Status: Superseded by 6.0.0 scope (unreleased)\n" + scope + "\n")
                self.write("docs/site/index.html", "<strong>9 Products</strong>\nThe 6.0 release contents are approved; readiness is not publication.\n")
                shutil.copyfile(VALIDATOR, self.root / "Scripts/validate_6_1_release_state.py")
                shutil.copyfile(ROOT / "Scripts/validate_6_release_state.sh", self.root / "Scripts/validate_6_release_state.sh")
                command = ["bash", str(self.root / "Scripts/validate_6_release_state.sh"), "--expect", "ready"]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.write("Scripts/symbols/budgets.tsv", "TOTAL\t1765\n")
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("TOTAL budget of 1764", result.stderr)

    def test_marker_only_ready_rejected(self):
        self.replace("docs/releases/6.1.0.md", "release-status: draft", "release-status: ready")
        self.rejected("matching first-line")

    def test_missing_marker_rejected(self):
        self.replace("API_STABILITY.md", "<!-- encoded-request-candidate: 6.1.0 -->", "")
        self.rejected("exactly one encoded-request")

    def test_unknown_inventory_marker_rejected(self):
        self.replace("API_STABILITY.md", "encoded-request-candidate", "encoded-request-approved")
        self.rejected("unknown encoded-request")

    def test_duplicate_inventory_marker_rejected(self):
        self.replace("API_STABILITY.md", "<!-- encoded-request-candidate: 6.1.0 -->",
                     "<!-- encoded-request-candidate: 6.1.0 -->\n<!-- encoded-request-release: 6.1.0 -->")
        self.rejected("exactly one encoded-request")

    def test_missing_unknown_duplicate_and_misplaced_note_markers(self):
        for replacement in ("", "<!-- release-status: pending -->",
                            "<!-- release-status: draft -->\n<!-- release-status: ready -->",
                            "\n<!-- release-status: draft -->"):
            with self.subTest(replacement=replacement):
                self.fixture("draft")
                self.replace("docs/releases/6.1.0.md", "<!-- release-status: draft -->", replacement)
                self.rejected("matching first-line")

    def test_ready_requires_release_inventory_marker(self):
        self.fixture("ready")
        self.replace("API_STABILITY.md", "encoded-request-release", "encoded-request-candidate")
        self.rejected("inventory marker.*disagree")

    def test_mixed_api_boundaries_rejected(self):
        for state in ("draft", "ready", "published"):
            with self.subTest(state=state):
                self.fixture(state)
                other = "ready" if state == "draft" else "draft"
                self.replace("API_STABILITY.md", MODULE.BOUNDARIES[state], MODULE.BOUNDARIES[other])
                self.rejected("API publication boundary")

    def test_mixed_symbol_description_rejected(self):
        self.fixture("ready")
        self.write("Scripts/symbols/README.md", MODULE.SYMBOL_DESCRIPTIONS["draft"])
        self.rejected("inventory description")

    def test_mixed_codec_ledger_rejected(self):
        self.fixture("ready")
        self.replace("API_STABILITY.md", MODULE.LEDGER_SUFFIXES["ready"], MODULE.LEDGER_SUFFIXES["published"])
        self.rejected("Stable codec ledger")

    def test_duplicate_codec_ledger_rejected(self):
        ledger = "- " + MODULE.CODEC_SYMBOLS + MODULE.LEDGER_SUFFIXES["draft"]
        self.replace("API_STABILITY.md", ledger, ledger + "\n" + ledger)
        self.rejected("exactly one entry")

    def test_draft_cannot_have_release_changelog(self):
        self.replace("CHANGELOG.md", "## [Unreleased]", "## [6.1.0] - 2020-01-02")
        self.rejected("Unreleased heading")

    def test_every_state_retains_exactly_one_leading_unreleased_heading(self):
        for state in ("draft", "ready", "published"):
            for replacement in ("", "## [Unreleased]\n## [Unreleased]", "## [Other]\n## [Unreleased]"):
                with self.subTest(state=state, replacement=replacement):
                    self.fixture(state)
                    self.replace("CHANGELOG.md", "## [Unreleased]", replacement)
                    self.rejected("Unreleased heading")

    def test_ready_requires_matching_changelog_date(self):
        self.fixture("ready")
        self.replace("CHANGELOG.md", "2020-01-02", "2020-01-03")
        self.rejected("changelog date")

    def test_ready_requires_real_date(self):
        for date in ("TBD", "2020-02-30", "2020-1-2"):
            with self.subTest(date=date):
                self.fixture("ready")
                self.replace("docs/releases/6.1.0.md", "2020-01-02", date)
                self.rejected("release date|day is out of range")

    def test_ready_requires_adoption_boundary(self):
        self.fixture("ready")
        self.replace("docs/releases/6.1.0.md", "Confirm the matching tag and GitHub Release before adopting 6.1.0.", "")
        self.rejected("Ready adoption boundary")

    def test_ready_rejects_stale_draft_readme(self):
        self.fixture("ready")
        self.write("README.md", "The 6.1 candidate on this branch is Draft and unpublished.")
        self.rejected("stale Draft")

    def test_draft_and_ready_reject_false_publication(self):
        for state in ("draft", "ready"):
            for path in ("README.md", "API_STABILITY.md", "CHANGELOG.md", "docs/releases/6.1.0.md", "Scripts/symbols/README.md"):
                for claim in ("`6.1.0` is published.", "The latest tagged stable release is 6.1.0.", "Released 6.1.0."):
                    with self.subTest(state=state, path=path, claim=claim):
                        self.fixture(state)
                        text = (self.root / path).read_text(encoding="utf-8")
                        self.write(path, text + "\n" + claim)
                        self.rejected("unverified 6.1 publication")

    def test_published_requires_evidence(self):
        self.fixture("published")
        self.write("Scripts/published-releases.json", json.dumps({"releases": [
            {"version": "6.0.0", "publishedAt": "2020-01-01T00:00:00Z",
             "url": "https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.0.0"}]}))
        self.rejected("publication evidence.*disagree")

    def test_published_rejects_actual_old_candidate_guidance_and_equivalents(self):
        claims = (
            "The 6.1 candidate is not published. Neither a Ready marker nor a green candidate workflow "
            "makes an unpublished version resolvable from SwiftPM.",
            "The `6.1.0` release remains unpublished.",
            "These notes describe the unpublished core 6.1 candidate.",
            "Until 6.1.0 is published, retain 6.0.0.",
        )
        for path in ("API_STABILITY.md", "README.md", "Scripts/symbols/README.md", "docs/releases/6.1.0.md"):
            for claim in claims:
                with self.subTest(path=path, claim=claim):
                    self.fixture("published")
                    self.write(path, (self.root / path).read_text() + "\n" + claim)
                    self.rejected("pending-publication guidance")

    def test_ready_rejects_publication_evidence(self):
        self.fixture("published")
        evidence = (self.root / "Scripts/published-releases.json").read_text(encoding="utf-8")
        self.fixture("ready")
        self.write("Scripts/published-releases.json", evidence)
        self.rejected("publication evidence.*disagree")

    def test_published_evidence_is_strict(self):
        for field, value in (("url", "https://example.com/releases/6.1.0"),
                             ("publishedAt", "2099-01-01T00:00:00Z"),
                             ("publishedAt", "2020-01-02"), ("publishedAt", "invalid")):
            with self.subTest(field=field, value=value):
                self.fixture("published")
                path = "Scripts/published-releases.json"
                evidence = json.loads((self.root / path).read_text(encoding="utf-8"))
                evidence["releases"][-1][field] = value
                self.write(path, json.dumps(evidence))
                self.rejected("invalid|future")

    def test_published_rejects_mismatched_note_timestamp(self):
        self.fixture("published")
        self.replace("docs/releases/6.1.0.md", "03:04:05Z", "03:04:06Z")
        self.rejected("publication timestamp")

    def test_published_rejects_wrong_utc_release_date(self):
        self.fixture("published")
        self.replace("docs/releases/6.1.0.md", "Release date: 2020-01-02", "Release date: 2020-01-03")
        self.replace("CHANGELOG.md", "2020-01-02", "2020-01-03")
        self.rejected("UTC publication date")

    def test_published_rejects_duplicate_evidence(self):
        self.fixture("published")
        path = "Scripts/published-releases.json"
        evidence = json.loads((self.root / path).read_text(encoding="utf-8"))
        evidence["releases"].append(evidence["releases"][-1])
        self.write(path, json.dumps(evidence))
        self.rejected("duplicate publication")


if __name__ == "__main__":
    unittest.main()
