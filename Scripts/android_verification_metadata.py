#!/usr/bin/env python3
"""Edit the strict Gradle dependency-verification files for a human update.

Dependabot cannot write verification-metadata.xml (dependabot-core#1996), so
Android updates land through a replacement PR. `clear` empties the components
before regeneration so no stale version survives. AGP resolves only the host's
aapt2 jar, so `add-aapt2-platforms` adds the other hosts' jars from Google
Maven, checked against the published SHA-1. `check` fails unless verification
stays strict and every aapt2 component lists all three host jars.
"""
import argparse
import hashlib
from pathlib import Path
import re
import sys
import urllib.request

AAPT2_URL = "https://dl.google.com/android/maven2/com/android/tools/build/aapt2/{version}/{name}"
AAPT2_ORIGIN = "Verified from the Google Maven repository"
HOSTS = ("linux", "osx", "windows")
STRICT = "<verify-metadata>true</verify-metadata>"
COMPONENTS = re.compile(r"<components>.*?</components>|<components/>", re.S)
AAPT2 = re.compile(r'(<component group="com\.android\.tools\.build" name="aapt2" version="([^"]+)">)(.*?)(\n *</component>)', re.S)
ARTIFACT = re.compile(r'\n *<artifact name="([^"]+)">.*?</artifact>', re.S)
# A build-numbered AGP release, e.g. 9.5.0-16666295. It also becomes a URL path.
AAPT2_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)+-[0-9]+")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def strict(text):
    require(text.count(STRICT) == 1, "dependency verification must stay strict")
    require(len(COMPONENTS.findall(text)) == 1, "expected exactly one components element")


def clear(text):
    strict(text)
    return COMPONENTS.sub("<components>\n   </components>", text)


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def host_artifact(version, host, download):
    name = f"aapt2-{version}-{host}.jar"
    url = AAPT2_URL.format(version=version, name=name)
    jar = download(url)
    published = download(url + ".sha1").decode("ascii").split()
    require(len(published) >= 1 and published[0].lower() == hashlib.sha1(jar).hexdigest(),
            name + " does not match its published SHA-1")
    sha256 = hashlib.sha256(jar).hexdigest()
    return name, (f'\n         <artifact name="{name}">'
                  f'\n            <sha256 value="{sha256}" origin="{AAPT2_ORIGIN}"/>'
                  f'\n         </artifact>')


def add_aapt2_platforms(text, download=fetch, cache=None):
    """Return text with every aapt2 component listing all three host jars."""
    strict(text)
    cache = {} if cache is None else cache

    def complete(match):
        head, version, body, tail = match.groups()
        require(bool(AAPT2_VERSION.fullmatch(version)), "unexpected aapt2 version: " + version)
        artifacts = [(m.group(1), m.group(0)) for m in ARTIFACT.finditer(body)]
        require("".join(block for _, block in artifacts) == body, "unexpected aapt2 component content")
        names = {name for name, _ in artifacts}
        require(any(f"aapt2-{version}-{host}.jar" in names for host in HOSTS),
                "aapt2 " + version + " resolved no host jar; regenerate with the Gradle tasks first")
        for host in HOSTS:
            name = f"aapt2-{version}-{host}.jar"
            if name in names:
                continue
            if (version, host) not in cache:
                cache[version, host] = host_artifact(version, host, download)
            # Gradle writes artifacts in name order; keep that order.
            artifacts.append(cache[version, host])
            artifacts.sort(key=lambda item: item[0])
        return head + "".join(block for _, block in artifacts) + tail

    return AAPT2.sub(complete, text)


def check(text):
    strict(text)
    require(COMPONENTS.search(text).group(0).count("<component ") > 0, "verification metadata has no components")
    for version, body in ((m.group(2), m.group(3)) for m in AAPT2.finditer(text)):
        names = set(ARTIFACT.findall(body))
        missing = [host for host in HOSTS if f"aapt2-{version}-{host}.jar" not in names]
        require(not missing, f"aapt2 {version} is missing host jars: {', '.join(missing)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("clear", "add-aapt2-platforms", "check"))
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    cache = {}
    try:
        for path in args.files:
            text = path.read_text(encoding="utf-8")
            if args.command == "check":
                check(text)
                continue
            updated = clear(text) if args.command == "clear" else add_aapt2_platforms(text, cache=cache)
            if updated != text:
                path.write_text(updated, encoding="utf-8")
    except (ValueError, OSError) as error:
        print(f"Android verification metadata: {error}", file=sys.stderr)
        return 1
    if args.command == "check":
        print("Android verification metadata: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
