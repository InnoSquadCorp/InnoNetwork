"""Run consumer validators with real child-process I/O and simulated tool results.

No Swift compiler, Xcode or network is used. Only the executable/arguments are
substituted; the validator's stdout/stderr routing and evidence writing are real.
"""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = next(parent for parent in Path(__file__).resolve().parents if (parent / "skills").is_dir())
SCRIPTS = sorted(ROOT.glob("skills/*/scripts/validate_consumer.py"))
WARNING = "warning: dependency 'swift-syntax' is not used by any target\n"


class ConsumerOutputTests(unittest.TestCase):
    def validate(self, script, case):
        spec = importlib.util.spec_from_file_location("consumer_output_subject", script)
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        support = json.loads((script.parents[1] / "references/support.json").read_text())
        expected = support.get("resolved_dependencies") or {"innodi": support, "swift-syntax": support["swift_syntax"]}
        real_popen = subprocess.Popen
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory).resolve()

            def popen(argv, *args, **kwargs):
                argv = [str(value) for value in argv]
                stdout, stderr, exit_code = "", "", 0
                if argv[:2] == ["swift", "--version"]:
                    stdout = "Simulated Swift toolchain\n"
                elif argv == ["xcodebuild", "-version"]:
                    stdout = "Simulated Xcode toolchain\n"
                elif argv[:2] == ["swift", "package"] and argv[-1] == "resolve":
                    dependencies = []
                    for identity, pin in expected.items():
                        (scratch / "checkouts" / identity).mkdir(parents=True)
                        dependencies.append({
                            "packageRef": {"identity": identity, "kind": "remoteSourceControl", "location": pin["repository"]},
                            "state": {"name": "sourceControlCheckout", "checkoutState": {
                                key: pin[key] for key in ("version", "revision") if pin.get(key) is not None
                            }},
                            "subpath": identity,
                        })
                    (scratch / "workspace-state.json").write_text(json.dumps({"object": {"dependencies": dependencies}}))
                elif argv[:2] == ["swift", "package"] and argv[-3:] == ["show-dependencies", "--format", "json"]:
                    stdout = json.dumps({"identity": "consumer", "dependencies": [
                        {"identity": identity, "url": pin["repository"], "version": pin.get("version") or "unspecified",
                         "path": str(scratch / "checkouts" / identity), "dependencies": []}
                        for identity, pin in expected.items()
                    ]})
                    if case != "clean":
                        stderr = WARNING
                    if case == "malformed":
                        stdout = "{not JSON"
                    elif case == "empty":
                        stdout = ""
                    elif case == "stdout-noise":
                        stdout = WARNING + stdout
                    elif case == "failure":
                        exit_code = 23
                elif argv[:2] == ["git", "ls-remote"]:
                    stdout = support["revision"] + "\t" + argv[3] + "\n"
                elif argv[:2] == ["git", "-C"]:
                    if argv[3:] == ["rev-parse", "HEAD"]:
                        stdout = expected[Path(argv[2]).name]["revision"] + "\n"
                    else:
                        self.assertEqual(argv[3:], ["status", "--porcelain", "--untracked-files=all"])
                elif argv[:2] == ["swift", "test"]:
                    # Swift Testing summaries can be on stderr. Text logs must
                    # keep their existing combined-output behavior.
                    stderr = "Test run with 14 tests in 1 suite passed\n"
                else:
                    self.fail(f"Unexpected tool invocation: {argv}")
                program = ("import sys; sys.stdout.write(" + repr(stdout) + "); "
                           "sys.stderr.write(" + repr(stderr) + "); sys.exit(" + str(exit_code) + ")")
                return real_popen([sys.executable, "-c", program], *args, **kwargs)

            output = io.StringIO()
            with patch.object(sys, "argv", [str(script), "--scratch-path", str(scratch)]), \
                    patch.object(sys, "platform", "darwin"), \
                    patch.dict(os.environ, {"INNONETWORK_LOCAL_PATH": ""}), \
                    patch.object(subprocess, "Popen", side_effect=popen), redirect_stdout(output):
                result = validator.main()
            evidence = json.loads(Path(json.loads(output.getvalue())["evidence"]).read_text())
            logs = {Path(entry["log"]).stem: Path(entry["log"]).read_text() for entry in evidence["commands"]}
            graph_entry, = [entry for entry in evidence["commands"] if "show-dependencies" in entry["argv"]]
            graph_log = Path(graph_entry["log"]).read_text()
            error_log = Path(graph_entry["stderr_log"]).read_text() if "stderr_log" in graph_entry else None
            return result, evidence, logs, graph_entry, graph_log, error_log

    def test_clean_graph_control(self):
        self.assertTrue(SCRIPTS)
        for script in SCRIPTS:
            with self.subTest(skill=script.parents[1].name):
                result, evidence, logs, _, graph, _ = self.validate(script, "clean")
                self.assertEqual((result, evidence["status"]), (0, "passed"), evidence.get("error"))
                self.assertEqual(json.loads(graph)["identity"], "consumer")
                self.assertIn("Test run with 14 tests", logs["swift-test"])

    def test_stderr_warning_preserved_without_poisoning_json(self):
        for script in SCRIPTS:
            with self.subTest(skill=script.parents[1].name):
                result, evidence, _, entry, graph, diagnostics = self.validate(script, "warning")
                self.assertEqual((result, evidence["status"]), (0, "passed"), evidence.get("error"))
                self.assertEqual(entry["exit_code"], 0)
                self.assertEqual(json.loads(graph)["identity"], "consumer")
                self.assertNotIn(WARNING, graph)
                self.assertEqual(diagnostics, WARNING)

    def test_invalid_stdout_is_not_repaired_or_accepted(self):
        for script in SCRIPTS:
            for case in ("malformed", "empty", "stdout-noise"):
                with self.subTest(skill=script.parents[1].name, case=case):
                    result, evidence, logs, entry, _, diagnostics = self.validate(script, case)
                    self.assertEqual((result, evidence["status"]), (1, "failed"))
                    self.assertEqual(entry["exit_code"], 0)
                    self.assertNotIn("swift-test", logs)
                    self.assertEqual(diagnostics, WARNING)

    def test_valid_json_does_not_hide_nonzero_exit(self):
        for script in SCRIPTS:
            with self.subTest(skill=script.parents[1].name):
                result, evidence, logs, entry, graph, diagnostics = self.validate(script, "failure")
                self.assertEqual((result, evidence["status"]), (1, "failed"))
                self.assertEqual(entry["exit_code"], 23)
                self.assertIn("failed (23)", evidence["error"])
                self.assertNotIn("swift-test", logs)
                self.assertEqual(json.loads(graph)["identity"], "consumer")
                self.assertEqual(diagnostics, WARNING)


if __name__ == "__main__":
    unittest.main()
