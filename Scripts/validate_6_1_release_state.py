#!/usr/bin/env python3
"""Validate the encoded-request inventory's lifecycle, independently of 6.0.

This is an offline consistency gate, not publication verification. A recorded
publication may only be added after checking the actual public tag and Release.
The historical 6.0 validator retains its original --expect/--print-state API.
"""

import argparse
from datetime import date, datetime, timezone
import json
from pathlib import Path
import re


CODEC_SYMBOLS = (
    "`EncodedRequest`, `EncodedRequestBody`, `EncodedRequestOptions`, "
    "`EncodedRequestClient`, `EncodedCodecMeasurement`, `EncodedPayloadFailure`"
)
LEDGER_SUFFIXES = {
    "draft": " (new in the unpublished 6.1 candidate)",
    "ready": " (new in 6.1.0; ready, not yet published)",
    "published": " (new in 6.1.0)",
}
BOUNDARIES = {
    "draft": "These additions are unpublished; they do not alter 6.0.0.",
    "ready": "These additions are approved for 6.1.0; readiness is not publication. They do not alter 6.0.0.",
    "published": "These additions shipped in 6.1.0; they do not alter 6.0.0.",
}
SYMBOL_DESCRIPTIONS = {
    "draft": "This table includes the approved, unpublished 6.1 encoded-request addition with",
    "ready": "This table includes the approved 6.1.0 encoded-request addition; readiness is not publication.",
    "published": "This table includes the published 6.1.0 encoded-request addition.",
}
STATUSES = {
    "draft": "Status: Draft, unpublished. Implementation and validation are authorized; this",
    "ready": "Status: Ready for release",
    "published": "Status: Published",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(root):
    paths = {
        "api": "API_STABILITY.md",
        "readme": "README.md",
        "changelog": "CHANGELOG.md",
        "symbols": "Scripts/symbols/README.md",
        "notes": "docs/releases/6.1.0.md",
    }
    documents = {key: (root / path).read_text(encoding="utf-8") for key, path in paths.items()}
    api, notes = documents["api"], documents["notes"]
    inventory_markers = re.findall(r"<!-- encoded-request-[^\n]*", api)
    require(len(inventory_markers) == 1, "API ledger requires exactly one encoded-request inventory marker")
    marker = inventory_markers[0]
    require(marker in ("<!-- encoded-request-candidate: 6.1.0 -->", "<!-- encoded-request-release: 6.1.0 -->"),
            "unknown encoded-request inventory marker")
    status_lines = [line for line in notes.splitlines() if line.startswith("Status:")]
    require(len(status_lines) == 1 and status_lines[0] in STATUSES.values(), "canonical 6.1 notes require one known Status line")
    state = next(state for state, status in STATUSES.items() if status == status_lines[0])
    expected_marker = "candidate" if state == "draft" else "release"
    require(marker == f"<!-- encoded-request-{expected_marker}: 6.1.0 -->", "inventory marker and canonical 6.1 status disagree")
    release_markers = re.findall(r"<!-- release-status:[^\n]*", notes)
    expected_status = "draft" if state == "draft" else "ready"
    require(release_markers == [f"<!-- release-status: {expected_status} -->"]
            and notes.startswith(release_markers[0] + "\n"), "canonical 6.1 notes require exactly one matching first-line release-status marker")

    # Read the same recorded evidence used by check_post_release_docs.rb. It is
    # deliberately not inferred from a Ready marker or an intended release date.
    evidence = json.loads((root / "Scripts/published-releases.json").read_text(encoding="utf-8"))
    releases = evidence["releases"]
    require(isinstance(releases, list) and releases, "publication evidence must contain releases")
    versions = []
    publication = None
    for release in releases:
        version = release["version"]
        require(isinstance(version, str) and re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version), "invalid published version")
        require(version not in versions, "duplicate publication evidence")
        versions.append(version)
        require(release["url"] == f"https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/{version}", "invalid release evidence URL")
        timestamp = release["publishedAt"]
        require(isinstance(timestamp, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})", timestamp), "invalid publication timestamp")
        published_at = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        require(published_at <= datetime.now(timezone.utc), "publication timestamp is in the future")
        if version == "6.1.0":
            publication = release
    require((publication is not None) == (state == "published"), "6.1 publication evidence and canonical status disagree")

    for other_state in STATUSES:
        boundary = BOUNDARIES[other_state]
        description = SYMBOL_DESCRIPTIONS[other_state]
        ledger = "- " + CODEC_SYMBOLS + LEDGER_SUFFIXES[other_state]
        require((boundary in api) == (other_state == state), "API publication boundary and 6.1 status disagree")
        require((description in documents["symbols"]) == (other_state == state), "symbol inventory description and 6.1 status disagree")
        require((ledger in api.splitlines()) == (other_state == state), "Stable codec ledger and 6.1 status disagree")
    codec_lines = [line for line in api.splitlines() if line.startswith("- " + CODEC_SYMBOLS)]
    require(codec_lines == ["- " + CODEC_SYMBOLS + LEDGER_SUFFIXES[state]], "Stable codec ledger must have exactly one entry")

    headings = re.findall(r"^## \[[^\n]+", documents["changelog"], re.MULTILINE)
    require(headings and headings[0] == "## [Unreleased]" and headings.count("## [Unreleased]") == 1,
            "all 6.1 states require exactly one leading Unreleased heading")
    dates = re.findall(r"^Release date: (.*)$", notes, re.MULTILINE)
    if state == "draft":
        require(not any(heading.startswith("## [6.1.0]") for heading in headings), "Draft 6.1 cannot have a dated changelog entry")
        require(not dates or dates == ["TBD"], "Draft 6.1 cannot have an approved release date")
        require("### Added — encoded request candidate (not published)" in documents["changelog"], "missing Draft changelog boundary")
        require("The 6.1 candidate on this branch is Draft and unpublished." in documents["readme"], "missing Draft README boundary")
    else:
        require(len(dates) == 1 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", dates[0]), "6.1 release notes require exactly one release date")
        date.fromisoformat(dates[0])
        require(headings.count(f"## [6.1.0] - {dates[0]}") == 1
                and sum(heading.startswith("## [6.1.0]") for heading in headings) == 1,
                "6.1 changelog date must match canonical notes")
        require("### Added — encoded requests" in documents["changelog"], "missing 6.1 changelog heading")
        for key, document in documents.items():
            for stale in ("The 6.1 candidate remains unpublished", "The 6.1 candidate on this branch is Draft",
                          "### Added — encoded request candidate (not published)", "document is not Ready approval",
                          "first-line Draft marker stays in place"):
                require(stale not in document, f"stale Draft boundary in {paths[key]}")
        if state == "ready":
            require("The 6.1.0 release contents are approved; readiness is not publication." in notes, "missing Ready publication boundary")
            require("Confirm the matching tag and GitHub Release before adopting 6.1.0." in notes, "missing Ready adoption boundary")
            require("The 6.1.0 contents are Ready for release; readiness is not publication." in documents["readme"], "missing Ready README boundary")
        else:
            published_lines = [line for line in notes.splitlines() if line.startswith("Published at:")]
            require(published_lines == [f"Published at: {publication['publishedAt']}"], "6.1 notes must match recorded publication timestamp")
            actual_date = datetime.fromisoformat(publication["publishedAt"].replace("Z", "+00:00")).astimezone(timezone.utc).date()
            require(dates[0] == actual_date.isoformat(), "6.1 release date must match recorded UTC publication date")
            require(publication["url"] in notes and publication["url"] in documents["readme"], "missing recorded 6.1 publication link")
            require("6.1.0 is published" in documents["readme"], "missing published README boundary")
            for key, document in documents.items():
                require("The 6.1.0 contents are Ready for release" not in document, f"stale Ready boundary in {paths[key]}")
                normalized = " ".join(document.replace("`", "").split())
                pending = (
                    r"\b6\.1(?:\.0)?(?: candidate| release)? (?:is|was|remains) (?:not(?: yet)? published|unpublished|pending publication)\b",
                    r"\b(?:unpublished|not[- ]yet[- ]published) (?:core )?6\.1(?:\.0)?\b",
                    r"\buntil 6\.1(?:\.0)? is (?:tagged|published|released)\b",
                )
                require(not any(re.search(pattern, normalized, re.IGNORECASE) for pattern in pending),
                        f"published 6.1 retains pending-publication guidance in {paths[key]}")

    if state != "published":
        claims = (
            r"\b6\.1(?:\.0)?(?: candidate| release)? (?:is|was|has been) (?:now )?(?:published|released|the latest (?:tagged )?stable release)\b",
            r"\b(?:latest (?:tagged )?stable release is|published|released|shipped in) 6\.1(?:\.0)?\b",
        )
        for key, document in documents.items():
            normalized = " ".join(document.replace("`", "").split())
            require(not any(re.search(pattern, normalized, re.IGNORECASE) for pattern in claims),
                    f"unverified 6.1 publication claim in {paths[key]}")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--print-codec-ledger", action="store_true")
    args = parser.parse_args()
    try:
        state = validate(args.root)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"6.1-release-state: {error}\n")
    print(CODEC_SYMBOLS + LEDGER_SUFFIXES[state] if args.print_codec_ledger else f"6.1-release-state: OK ({state})")


if __name__ == "__main__":
    main()
