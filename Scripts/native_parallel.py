"""Strict, deliberately small native-step parallel compatibility for actionlint.

Only reviewed parallel groups of 2..10 ordinary run steps are supported. This
is NOT a runtime transpiler: GitHub receives the original native YAML. The
line-preserving projection lets old actionlint validate every child normally.
Unknown native constructs, conditional/error-tolerant children and shared step
outputs are rejected rather than suppressed.
"""
import re

CONTROL = re.compile(r'^\s*(?:-\s*)?(parallel|background|wait-all|wait|cancel)\s*:')
GROUP = re.compile(r'^      - parallel:\s*(?:#.*)?$')
MEMBER = re.compile(r'^          - (name|run):(?:\s|$)')
KEY = re.compile(r'^            ([\w-]+):(?:\s|$)')
ALLOWED = {'name', 'run', 'shell', 'timeout-minutes'}


def project(text):
    """Return same-line-count YAML for static lint; fail closed on new syntax."""
    lines = text.splitlines(keepends=True)
    result = list(lines)
    index = 0
    in_steps = False
    while index < len(lines):
        line = lines[index]
        if line.strip() and not line.lstrip().startswith('#') and len(line)-len(line.lstrip()) <= 4:
            in_steps = line.rstrip() == '    steps:'
        match = CONTROL.match(line)
        if not match:
            index += 1
            continue
        if not GROUP.fullmatch(line.rstrip('\r\n')) or not in_steps:
            raise ValueError(f'line {index+1}: unsupported native control; only job-level parallel groups are reviewed')
        end = index + 1
        while end < len(lines):
            candidate = lines[end]
            if candidate.strip() and not candidate.lstrip().startswith('#') and len(candidate)-len(candidate.lstrip()) <= 6:
                break
            end += 1
        members = [n for n in range(index+1,end) if MEMBER.match(lines[n])]
        if not 2 <= len(members) <= 10:
            raise ValueError(f'line {index+1}: parallel requires 2..10 ordinary run steps')
        # Everything before the first member must be blank/comment.
        if any(v.strip() and not v.lstrip().startswith('#') for v in lines[index+1:members[0]]):
            raise ValueError('parallel group has an unsupported mapping or sequence shape')
        names = set()
        for start, stop in zip(members, members[1:]+[end]):
            keys = []
            for n in range(start,stop):
                value = lines[n]
                if not value.strip() or value.lstrip().startswith('#'):
                    continue
                indent = len(value)-len(value.lstrip())
                if n == start:
                    key = MEMBER.match(value).group(1)
                elif indent == 12:
                    m = KEY.match(value)
                    if not m:
                        raise ValueError(f'line {n+1}: invalid parallel child key')
                    key = m.group(1)
                elif indent > 12:
                    # Only a run literal/folded block may contain deeper content.
                    if not keys or keys[-1] != 'run' or not re.search(r'run:\s*[|>][-+]?\s*(?:#.*)?$', lines[run_line].rstrip()):
                        raise ValueError(f'line {n+1}: nested child mappings are unsupported')
                    continue
                else:
                    raise ValueError(f'line {n+1}: malformed parallel child indentation')
                if key not in ALLOWED or key in keys:
                    raise ValueError(f'line {n+1}: unsupported or duplicate parallel child key: {key}')
                keys.append(key)
                if key == 'run':
                    run_line = n
                if key == 'name':
                    name = value.split('name:',1)[1].strip()
                    if not name or name in names or name[0] in '&*!{[' or '${{' in name:
                        raise ValueError('parallel child names must be unique literal scalars')
                    names.add(name)
            if 'run' not in keys or 'name' not in keys:
                raise ValueError('parallel child requires name and run')
            body = ''.join(lines[start:stop])
            if re.search(r'\$\{\{\s*(?:steps\.|env\.)|GITHUB_(?:ENV|OUTPUT|PATH|STEP_SUMMARY)', body):
                raise ValueError('parallel children cannot publish environment/output or depend on mutable step state')
        result[index] = '      # Native parallel group validated; serial projection is lint-only.\n'
        for n in range(index+1,end):
            value = lines[n]
            if value.strip() and not value.lstrip().startswith('#'):
                if len(value)-len(value.lstrip()) < 10:
                    raise ValueError('invalid native group indentation')
                result[n] = value[4:]
        index = end
    return ''.join(result)


def lint_projection(workflows, destination):
    """Project files without hiding old-linter diagnostics or changing originals."""
    projected, sources = [], {}
    for source in workflows:
        original = source.read_text()
        rendered = project(original)
        if rendered == original:
            projected.append(source)
            continue
        target = destination / source.name
        target.write_text(rendered)
        projected.append(target)
        sources[str(target.resolve())] = (source.resolve(), original.splitlines(), rendered.splitlines())
    return projected, sources


def restore_diagnostics(result, sources, root):
    import json
    from pathlib import Path
    if result.returncode not in (0, 1) or result.stderr:
        return result
    diagnostics = json.loads(result.stdout)
    if not isinstance(diagnostics, list):
        raise ValueError('invalid actionlint diagnostics')
    for diagnostic in diagnostics:
        path = Path(diagnostic['filepath'])
        key = str((root / path).resolve())
        if key in sources:
            source, original, rendered = sources[key]
            diagnostic['filepath'] = str(source)
            index = diagnostic['line'] - 1
            if 0 <= index < len(original) and original[index] != rendered[index] and rendered[index] == original[index][4:]:
                diagnostic['column'] += 4
    result.stdout = json.dumps(diagnostics)
    return result
