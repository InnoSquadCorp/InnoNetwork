# HLS Runtime Fixtures

These checked-in media files exercise AVFoundation playback without reaching
an external service. Runtime smoke scripts serve this directory from an
ephemeral loopback HTTP port; tests must not treat a `file://` playlist as an
equivalent HLS playback path.

## `audio-fmp4`

The fixture is a two-second, mono, 48 kHz AAC-LC sine wave packaged as a VOD
fragmented-MP4 HLS presentation. It was generated once with FFmpeg 9.0.1:

```bash
ffmpeg -f lavfi \
  -i 'sine=frequency=440:sample_rate=48000:duration=2' \
  -c:a aac -b:a 64k -ac 1 \
  -f hls -hls_time 1 -hls_list_size 0 -hls_playlist_type vod \
  -hls_flags independent_segments \
  -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
  -hls_segment_filename 'segment-%d.m4s' index.m3u8
```

The runtime gate verifies these SHA-256 digests before starting playback:

| File | SHA-256 |
|---|---|
| `index.m3u8` | `6b38193f703ab2b9f8243cf3c6350ab15d5914996c209e2840842404b76ab1ab` |
| `init.mp4` | `0d52787f0585a037f250d945f6fbbe937bada97c3a194e3c700af51978b089ce` |
| `segment-0.m4s` | `d48fbab061c99e1a66d6b37b6fb020904b21af03c90da83141dc02ad9f2cab4e` |
| `segment-1.m4s` | `1a35ff6feaea26609b1602a50cb69fa6ce4cc15ca8e6e269d777154e3ca2fddf` |
| `segment-2.m4s` | `863096b38668959a66385bc34a3f67e71c9664e1ebcabb45e7d82309f9272ee9` |

Do not regenerate the fixture during CI. Updating any media file requires an
intentional digest update, Apple HLS tool validation, and a real AVPlayer
runtime smoke run.
