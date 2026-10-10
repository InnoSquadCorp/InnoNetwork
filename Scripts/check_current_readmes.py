#!/usr/bin/env python3
"""Offline structure/link/example checks; not compilation or translation review."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('en', 'ko', 'es', 'de', 'zh-Hans', 'ja', 'ru')
PATHS = [ROOT / ('README.md' if lang == 'en' else f'README.{lang}.md') for lang in LANGUAGES]
REQUIRED = (
    '6.1.1', '6.2', '44e4ca28c50c03f817231a077c0f3bdfdbc859c8',
    'InnoNetworkAuthAWS', 'InnoNetworkDownload', 'InnoNetworkUpload',
    'InnoNetworkWebSocket', 'InnoNetworkPersistentCache', 'InnoNetworkOpenAPI',
    'InnoNetworkTrust', 'InnoNetworkTestSupport', 'InnoNetworkMacroSupport',
    'InnoNetwork-Stream', 'InnoNetwork-Protobuf', 'InnoNetworkHLSAudio',
    'EncodedRequest', 'NetworkError', 'NetworkFailure', 'OperationNetworkClient',
    'safeDefaults', 'shutdown()', 'cancelAll()', 'traits: []', '401', '403',
    'API_STABILITY.md', 'docs/Migration-6.0.0.md', 'docs/Migration-EncodedRequests.md',
    'docs/ko/README.md', 'SECURITY.md', 'SUPPORT.md', 'LICENSE',
)


def validate(root=ROOT):
    errors = []
    translated_blocks = None
    for lang in LANGUAGES:
        path = root / ('README.md' if lang == 'en' else f'README.{lang}.md')
        if not path.is_file():
            errors.append(f'{path.name}: missing')
            continue
        text = path.read_text(encoding='utf-8')
        for token in REQUIRED:
            if token not in text:
                errors.append(f'{path.name}: missing shared contract {token}')
        for other in LANGUAGES:
            name = 'README.md' if other == 'en' else f'README.{other}.md'
            if f']({name})' not in text:
                errors.append(f'{path.name}: missing language link {name}')
        if text.count('```') % 2:
            errors.append(f'{path.name}: unbalanced fenced code')
        for match in re.finditer(r'(?<!!)\[[^\]\n]+\]\(([^)\s]+)\)', text):
            url = match.group(1)
            target = urlsplit(url)
            if target.scheme or not target.path:
                continue
            if not (path.parent / unquote(target.path)).exists():
                errors.append(f'{path.name}: broken local link {url}')
        if lang != 'en':
            blocks = re.findall(r'```swift\n(.*?)\n```', text, re.S)
            if len(blocks) != 4:
                errors.append(f'{path.name}: expected install/request/error/operation examples')
            if translated_blocks is None:
                translated_blocks = blocks
            elif blocks != translated_blocks:
                errors.append(f'{path.name}: localized Swift examples differ')
            if len(re.findall(r'^## ', text, re.M)) != 9:
                errors.append(f'{path.name}: expected nine shared guide sections')
    return errors


if __name__ == '__main__':
    errors = validate()
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        raise SystemExit(1)
    print('current-readmes: seven languages; shared contracts, 24 translated Swift blocks, local links OK')
    print('Not checked: Swift compilation, rendered DocC, native-language review, external URL availability')
