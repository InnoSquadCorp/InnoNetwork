#!/usr/bin/env python3
"""Serve checked-in HLS runtime fixtures from an ephemeral loopback port."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
from pathlib import Path
import sys


class FixtureRequestHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".m4s": "audio/iso.segment",
        ".mp4": "audio/mp4",
    }

    def log_message(self, format: str, *args: object) -> None:
        print(f"hls-runtime-server: {format % args}", file=sys.stderr)


def write_ready_file(path: Path, base_url: str) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(f"{base_url}\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_root", type=Path)
    parser.add_argument("ready_file", type=Path)
    arguments = parser.parse_args()

    fixture_root = arguments.fixture_root.resolve()
    if not fixture_root.is_dir():
        raise SystemExit(
            f"hls-runtime-server: fixture root is missing: {fixture_root}"
        )
    if arguments.ready_file.exists():
        raise SystemExit(
            "hls-runtime-server: ready file must not already exist: "
            f"{arguments.ready_file}"
        )

    handler = functools.partial(
        FixtureRequestHandler,
        directory=str(fixture_root),
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    port = server.server_address[1]
    write_ready_file(arguments.ready_file, f"http://127.0.0.1:{port}")
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
