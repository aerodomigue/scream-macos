# ScreamBar

macOS menubar app that can either manage a [Scream](https://github.com/duncanthrax/scream) receiver with JACK or route one CoreAudio input directly to an output device.

Scream receives audio from a Windows VM (or any Scream sender) over the network and outputs it through JACK Audio Connection Kit on macOS.

## Prerequisites

- macOS 13 (Ventura) or later
- [JACK](https://jackaudio.org/) via Homebrew, required only for Scream mode:
  ```
  brew install jack
  ```

### Scream binary

`make build` requires a `scream` binary compiled with JACK support placed at the root of this repo. The standard releases from [duncanthrax/scream](https://github.com/duncanthrax/scream#receivers) do not include macOS/JACK builds, so you need to compile it from source:

```bash
git clone https://github.com/duncanthrax/scream.git
cd scream/Receivers/unix

# Install build dependencies
brew install cmake pkg-config

cmake . -DUSE_JACK=ON
make
```

Then copy the resulting `scream` binary to the root of this repo:

```bash
cp scream /path/to/scream-macos/scream
```

## Build & Install

```bash
# Development run
make dev-run

# Build release .app bundle
make build

# Install to /Applications
make install
```

## Usage

ScreamBar runs as a menubar-only app (no dock icon). Click the speaker icon to open the control panel.

### Status tab
Start/stop JACK and Scream individually or together. Color indicators show service state:
- Green: running
- Red: stopped
- Yellow: starting/stopping
- Orange: error

### Settings tab
Choose the application mode and configure its parameters:
- **Scream**: multicast/unicast, port, JACK sample rate and buffer size
- **Direct Routing**: CoreAudio input/output devices and an optional explicit buffer size from 64 to 2048 frames

Direct Routing stores device UIDs. If a preferred output disappears, the app temporarily uses the macOS default output and automatically restores the preferred output when it returns. Input devices do not fall back silently.

Settings are saved automatically and persist across restarts.

### Logs tab
Real-time stdout/stderr output from both JACK and Scream processes.

## Network permissions

On first launch, macOS will show a firewall popup asking to allow network connections for `scream`. Accept this — it's required for receiving audio in both unicast and multicast modes.

## How it works

In Scream mode, ScreamBar manages two processes:
1. `jackd -d coreaudio` — JACK audio server
2. `scream -o jack [options]` — Scream network audio receiver

If JACK is already running (started manually or by another app), ScreamBar detects it and won't try to manage its lifecycle.

Direct Routing uses one shared-mode AUHAL. Separate input/output devices are combined in a process-private Aggregate Device after negotiating a common hardware sample rate. It does not change the macOS default output or request exclusive device access.

The default `Automatic` buffer mode leaves device settings unchanged. Explicit buffer sizes are validated against both devices, applied before route creation, and restored when Direct Routing stops. Lower sizes reduce latency but can cause dropouts, particularly with Bluetooth devices.

Run the unit and contract tests with `swift test`. Hardware coexistence tests are opt-in because they open the microphone and output devices: grant audio-input permission, then run `SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS=1 swift test`.
