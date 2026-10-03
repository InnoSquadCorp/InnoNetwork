"""Supply-chain and compatibility boundaries of the required workflow linter."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('workflow_lint', ROOT / 'Scripts/check-ci-workflows.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class WorkflowLintTests(unittest.TestCase):
    def test_only_verified_regular_executable_is_written(self):
        for symlink in (False, True):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
                member = tarfile.TarInfo('actionlint')
                content = b'#!/bin/sh\nexit 0\n'
                if symlink:
                    member.type = tarfile.SYMTYPE
                    member.linkname = '/untrusted/executable'
                    archive.addfile(member)
                else:
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
            data = buffer.getvalue()
            with tempfile.TemporaryDirectory() as directory:
                destination = Path(directory)
                digest = hashlib.sha256(data).hexdigest()
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    p.unpack_verified(data + b'tampered', digest, destination)
                self.assertEqual(list(destination.iterdir()), [])
                if symlink:
                    with self.assertRaisesRegex(ValueError, 'regular executable'):
                        p.unpack_verified(data, digest, destination)
                    self.assertEqual(list(destination.iterdir()), [])
                else:
                    executable = p.unpack_verified(data, digest, destination)
                    self.assertEqual(executable.read_bytes(), content)
                    self.assertEqual(executable.stat().st_mode & 0o777, 0o700)

    def test_queue_lint_exception_cannot_hide_invalid_or_new_queue_values(self):
        original = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'dependabot-auto-merge.yml'
            path.write_text(original)
            p.check_queue_compatibility([ROOT / '.github/workflows/ci.yml', path, ROOT / '.github/workflows/dependency-submission.yml', ROOT / '.github/workflows/pr-dependency-submission.yml'])
            for changed in (
                    original.replace('      queue: max', '      queue: invalid', 1),
                    original.replace('      queue: max\n', '', 1),
                    original.replace('      queue: max', '      queue: max\n      queue: max', 1),
                    original + '\n  unreviewed:\n    concurrency:\n      queue: max\n',
                    original + '\n  unreviewed:\n    concurrency:\n      "queue": max\n'):
                path.write_text(changed)
                with self.assertRaises(ValueError):
                    p.check_queue_compatibility([ROOT / '.github/workflows/ci.yml', path, ROOT / '.github/workflows/dependency-submission.yml', ROOT / '.github/workflows/pr-dependency-submission.yml'])

    def test_diagnostics_exempt_only_exact_reviewed_queue_locations(self):
        paths = list((ROOT / '.github/workflows').glob('*.yml'))
        allowed = p.check_queue_compatibility(paths)
        errors = [dict(filepath=path, line=line, column=column, kind='syntax-check', message=p.QUEUE_DIAGNOSTIC)
                  for path, line, column in sorted(allowed)]
        def result(values, code=1, stderr=''):
            return subprocess.CompletedProcess([], code, json.dumps(values), stderr)
        p.require_clean_diagnostics(result(errors), allowed, ROOT)
        # YAML flow syntax can introduce queue on a different line/column
        # without matching the compatibility precheck's block-syntax pattern.
        for extra in (dict(errors[0], line=999), dict(errors[0], column=40),
                      dict(errors[0], filepath=str(ROOT / '.github/workflows/other.yml')),
                      dict(errors[0], message='invalid workflow'), dict(errors[0], kind='expression')):
            with self.assertRaises(ValueError):
                p.require_clean_diagnostics(result(errors + [extra]), allowed, ROOT)
        for output in (result(errors + [errors[0]]), result(errors[1:]), result([], 0),
                       result(None), result(errors, 2), result(errors, stderr='fatal error')):
            with self.assertRaises(ValueError):
                p.require_clean_diagnostics(output, allowed, ROOT)

    def test_ci_queue_exception_rejects_condition_or_location_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            copies=[]
            for source in (ROOT / '.github/workflows').glob('*.yml'):
                path=Path(directory)/source.name;path.write_text(source.read_text());copies.append(path)
            p.check_queue_compatibility(copies)
            name, line=next((key[0],line) for key,line in p.QUEUE_LOCATIONS.items() if key[1] is None)
            candidate=next(x for x in copies if x.name==name);original=candidate.read_text()
            for changed in [original.replace(line,line.replace("'max'", "'single'")),
                            original.replace(line+'\n',''),
                            original.replace(line,line+'\n'+line),
                            original.replace(line,'    '+line)]:
                candidate.write_text(changed)
                with self.assertRaises(ValueError):p.check_queue_compatibility(copies)
