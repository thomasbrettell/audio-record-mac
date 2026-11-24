# audiorec

macOS CLI that records system audio and microphone audio (ScreenCaptureKit).

    swift build -c release
    .build/release/audiorec -o ~/Recordings/test --duration 10

Outputs `system.m4a` and `mic.m4a` in the output directory (separate tracks,
timestamps are synchronized). Stop with Ctrl-C.

## Options

| Option | Description |
| --- | --- |
| `-o, --output <dir>` | Output directory (default: `~/audio-record-mac-recordings/recording-<timestamp>`) |
| `--no-mic` | Record system audio only |
| `--mix` | Also write `mixed.m4a` (system + mic combined) |
| `--mic-device <id>` | Microphone device uniqueID (default: system default) |
| `--duration <secs>` | Stop automatically after N seconds |
| `--list-mics` | List microphones and exit |
| `-h, --help` | Show usage |

Requirements: macOS 15+, Xcode/Swift 5.9+. Grant your terminal app
Screen Recording and Microphone permission in System Settings > Privacy & Security.

Merge into one file (optional):

    ffmpeg -i system.m4a -i mic.m4a -filter_complex amix=inputs=2 mixed.m4a
