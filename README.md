# ScreamBar

macOS menubar app that manages [Scream](https://github.com/duncanthrax/scream) audio receiver with JACK backend.

Scream receives audio from a Windows VM (or any Scream sender) over the network and outputs it through JACK Audio Connection Kit on macOS.

## Prerequisites

- macOS 13 (Ventura) or later
- [JACK](https://jackaudio.org/) via Homebrew:
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
Configure Scream receiver parameters:
- **Network**: unicast/multicast mode, port, interface, group address
- **JACK**: client name, auto-connect ports
- **Advanced**: target/max latency, verbose logging

Settings are saved automatically and persist across restarts.

### Logs tab
Real-time stdout/stderr output from both JACK and Scream processes.

## Network permissions

On first launch, macOS will show a firewall popup asking to allow network connections for `scream`. Accept this — it's required for receiving audio in both unicast and multicast modes.

## How it works

ScreamBar manages two processes:
1. `jackd -d coreaudio` — JACK audio server
2. `scream -o jack [options]` — Scream network audio receiver

If JACK is already running (started manually or by another app), ScreamBar detects it and won't try to manage its lifecycle.
