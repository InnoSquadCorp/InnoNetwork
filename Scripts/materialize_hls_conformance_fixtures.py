#!/usr/bin/env python3
"""Materialize the embedded HLS media fixtures for external validators."""

from __future__ import annotations

import argparse
import base64
import binascii
import re
import textwrap
from pathlib import Path


FIXTURES = {
    "transport-stream/index.m3u8": ("transportStreamPlaylist", "text"),
    "transport-stream/segment-0.ts": ("transportStreamSegment0Base64", "base64"),
    "fragmented-mp4/index.m3u8": ("fragmentedMP4Playlist", "text"),
    "fragmented-mp4/init.mp4": ("fragmentedMP4InitializationBase64", "base64"),
    "fragmented-mp4/segment-0.m4s": ("fragmentedMP4Segment0Base64", "base64"),
    "fragmented-mp4/segment-1.m4s": ("fragmentedMP4Segment1Base64", "base64"),
}


def fail(message: str) -> None:
    raise SystemExit(f"hls-conformance-fixtures: {message}")


def multiline_literal(source: str, name: str) -> str:
    pattern = re.compile(
        rf"(?m)^\s*(?:private\s+)?static\s+let\s+{re.escape(name)}\s*=\s*"
        r'"""\n(?P<body>.*?)^\s*"""$',
        re.DOTALL,
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        fail(f"expected exactly one Swift multiline literal named {name}")
    return textwrap.dedent(matches[0].group("body"))


def decoded_base64(value: str, name: str) -> bytes:
    try:
        return base64.b64decode("".join(value.split()), validate=True)
    except (binascii.Error, ValueError) as error:
        fail(f"{name} is not valid base64: {error}")


def materialize(source_path: Path, output_directory: Path) -> None:
    if not source_path.is_file():
        fail(f"fixture source is missing: {source_path}")
    if output_directory.exists() and any(output_directory.iterdir()):
        fail(f"output directory must be empty: {output_directory}")

    source = source_path.read_text(encoding="utf-8")
    output_directory.mkdir(parents=True, exist_ok=True)

    for relative_path, (literal_name, encoding) in FIXTURES.items():
        value = multiline_literal(source, literal_name)
        destination = output_directory / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if encoding == "base64":
            destination.write_bytes(decoded_base64(value, literal_name))
        else:
            destination.write_text(value, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output_directory", type=Path)
    arguments = parser.parse_args()

    materialize(
        arguments.source.resolve(),
        arguments.output_directory.resolve(),
    )
    print(
        "hls-conformance-fixtures: materialized "
        f"{len(FIXTURES)} files in {arguments.output_directory}"
    )


if __name__ == "__main__":
    main()
