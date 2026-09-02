#!/usr/bin/env python3
"""Serve checked-in HLS runtime fixtures from an ephemeral loopback port."""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlsplit


class LivePreloadState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._playlist_requests = 0
        self._resource_requests = {
            "initialization_map": 0,
            "first_part": 0,
            "second_part": 0,
            "complete_parent": 0,
        }
        self._resource_started = {
            "initialization_map": threading.Event(),
            "first_part": threading.Event(),
            "second_part": threading.Event(),
        }
        self._first_reload_saw_preloads = False
        self._second_reload_saw_preload = False

    def next_playlist_generation(self) -> int:
        with self._lock:
            generation = self._playlist_requests
            self._playlist_requests += 1
            return generation

    def mark_resource(self, name: str) -> None:
        with self._lock:
            self._resource_requests[name] += 1
        event = self._resource_started.get(name)
        if event is not None:
            event.set()

    def await_first_preloads(self) -> None:
        saw_map = self._resource_started["initialization_map"].wait(
            timeout=5
        )
        saw_part = self._resource_started["first_part"].wait(timeout=5)
        with self._lock:
            self._first_reload_saw_preloads = saw_map and saw_part

    def await_second_part_preload(self) -> None:
        saw_part = self._resource_started["second_part"].wait(timeout=5)
        with self._lock:
            self._second_reload_saw_preload = saw_part

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {
                "playlist_requests": self._playlist_requests,
                **self._resource_requests,
                "first_reload_saw_preloads": self._first_reload_saw_preloads,
                "second_reload_saw_preload": self._second_reload_saw_preload,
            }


class LiveGapState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._gap_resource_requests = 0

    def mark_gap_resource(self) -> None:
        with self._lock:
            self._gap_resource_requests += 1

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {"gap_resource_requests": self._gap_resource_requests}


class FixtureRequestHandler(http.server.SimpleHTTPRequestHandler):
    preload_state: LivePreloadState
    gap_state: LiveGapState

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".m4s": "audio/iso.segment",
        ".mp4": "audio/mp4",
    }

    def log_message(self, format: str, *args: object) -> None:
        print(f"hls-runtime-server: {format % args}", file=sys.stderr)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/live-preload/index.m3u8":
            self._serve_live_preload_playlist()
            return
        if path == "/live-map-rotation/index.m3u8":
            self._serve_live_map_rotation_playlist()
            return
        if path == "/live-gap/index.m3u8":
            self._serve_live_gap_playlist()
            return
        if path == "/live-timeshift/index.m3u8":
            self._serve_live_timeshift_playlist()
            return
        if path == "/live-preload/state":
            self._send_json(self.preload_state.snapshot())
            return
        if path == "/live-gap/state":
            self._send_json(self.gap_state.snapshot())
            return
        if path == "/live-gap/segment-1.m4s":
            self.gap_state.mark_gap_resource()
            self.send_error(404)
            return
        rotation_resources = {
            "/live-map-rotation/init-a.mp4": "init.mp4",
            "/live-map-rotation/init-b.mp4": "init.mp4",
            "/live-map-rotation/segment-0.m4s": "segment-0.m4s",
            "/live-map-rotation/segment-1.m4s": "segment-1.m4s",
            "/live-map-rotation/segment-2.m4s": "segment-2.m4s",
            "/live-gap/init.mp4": "init.mp4",
            "/live-gap/segment-0.m4s": "segment-0.m4s",
            "/live-gap/segment-2.m4s": "segment-2.m4s",
            "/live-timeshift/init.mp4": "init.mp4",
        }
        rotation_resource = rotation_resources.get(path)
        if rotation_resource is not None:
            self._send_runtime_fixture(rotation_resource)
            return
        timeshift_resources = {
            "/live-timeshift/segment-0.m4s": ("segment-0.m4s", 0.2),
            "/live-timeshift/segment-1.m4s": ("segment-1.m4s", 1.2),
            "/live-timeshift/segment-2.m4s": ("segment-2.m4s", 0),
        }
        timeshift_resource = timeshift_resources.get(path)
        if timeshift_resource is not None:
            name, delay = timeshift_resource
            self._send_runtime_fixture(name, delay=delay)
            return
        resources = {
            "/live-preload/init.mp4": (
                "initialization_map",
                b"runtime-init",
                "audio/mp4",
            ),
            "/live-preload/11.0.m4s": (
                "first_part",
                b"runtime-one",
                "audio/iso.segment",
            ),
            "/live-preload/11.1.m4s": (
                "second_part",
                b"runtime-two",
                "audio/iso.segment",
            ),
            "/live-preload/11.m4s": (
                "complete_parent",
                b"runtime-parent",
                "audio/iso.segment",
            ),
        }
        resource = resources.get(path)
        if resource is not None:
            name, body, content_type = resource
            self.preload_state.mark_resource(name)
            self._send_bytes(body, content_type)
            return
        super().do_GET()

    def _serve_live_preload_playlist(self) -> None:
        generation = self.preload_state.next_playlist_generation()
        if generation == 0:
            playlist = """#EXTM3U
#EXT-X-VERSION:10
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:11
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
#EXT-X-PART-INF:PART-TARGET=1
#EXT-X-PRELOAD-HINT:TYPE=MAP,URI="init.mp4"
#EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.0.m4s"
"""
        elif generation == 1:
            self.preload_state.await_first_preloads()
            playlist = """#EXTM3U
#EXT-X-VERSION:10
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:11
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
#EXT-X-PART-INF:PART-TARGET=1
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
#EXT-X-PRELOAD-HINT:TYPE=PART,URI="11.1.m4s"
"""
        else:
            self.preload_state.await_second_part_preload()
            playlist = """#EXTM3U
#EXT-X-VERSION:10
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:11
#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=2
#EXT-X-PART-INF:PART-TARGET=1
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PART:DURATION=1,URI="11.0.m4s",INDEPENDENT=YES
#EXT-X-PART:DURATION=1,URI="11.1.m4s"
#EXTINF:2,
11.m4s
#EXT-X-ENDLIST
"""
        self._send_bytes(
            playlist.encode("utf-8"),
            "application/vnd.apple.mpegurl",
        )

    def _serve_live_map_rotation_playlist(self) -> None:
        playlist = """#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init-a.mp4"
#EXTINF:1.002667,
segment-0.m4s
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-b.mp4"
#EXTINF:1.002667,
segment-1.m4s
#EXT-X-DISCONTINUITY
#EXT-X-MAP:URI="init-a.mp4"
#EXTINF:0.021333,
segment-2.m4s
#EXT-X-ENDLIST
"""
        self._send_bytes(
            playlist.encode("utf-8"),
            "application/vnd.apple.mpegurl",
        )

    def _serve_live_gap_playlist(self) -> None:
        playlist = """#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1.002667,
segment-0.m4s
#EXT-X-GAP
#EXTINF:1.002667,
segment-1.m4s
#EXTINF:0.021333,
segment-2.m4s
#EXT-X-ENDLIST
"""
        self._send_bytes(
            playlist.encode("utf-8"),
            "application/vnd.apple.mpegurl",
        )

    def _serve_live_timeshift_playlist(self) -> None:
        playlist = """#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init.mp4"
#EXTINF:1.002667,
segment-0.m4s
#EXTINF:1.002667,
segment-1.m4s
#EXTINF:0.021333,
segment-2.m4s
#EXT-X-ENDLIST
"""
        self._send_bytes(
            playlist.encode("utf-8"),
            "application/vnd.apple.mpegurl",
        )

    def _send_runtime_fixture(self, name: str, delay: float = 0) -> None:
        fixture = Path(self.directory) / "audio-fmp4" / name
        content_type = self.extensions_map.get(
            fixture.suffix,
            "application/octet-stream",
        )
        if delay > 0:
            time.sleep(delay)
        self._send_bytes(fixture.read_bytes(), content_type)

    def _send_json(self, value: dict[str, object]) -> None:
        body = (json.dumps(value, sort_keys=True) + "\n").encode("utf-8")
        self._send_bytes(body, "application/json")

    def _send_bytes(self, body: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


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

    FixtureRequestHandler.preload_state = LivePreloadState()
    FixtureRequestHandler.gap_state = LiveGapState()
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
