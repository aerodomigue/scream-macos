# ScreamBar

ScreamBar is a macOS menu bar application with two mutually exclusive audio modes:

- **Scream** receives audio sent over the network by a [Scream](https://github.com/duncanthrax/scream) sender and plays it through JACK.
- **Direct Routing** sends one CoreAudio input device directly to one CoreAudio output device without JACK or network capture.

ScreamBar runs as a menu bar-only application and requires macOS 13 Ventura or later.

## Requirements

### Direct Routing mode

Direct Routing uses macOS CoreAudio and has no external runtime dependency. It requests microphone/audio-input permission only when a direct route is started. It does not request Screen Recording or system-audio-capture permission.

For permission testing, run the generated `.app` bundle. A plain `swift run` executable does not include the bundle's microphone usage description.

### Scream mode

Scream mode requires JACK and a Scream Unix receiver compiled with JACK support:

```bash
brew install jack libsoxr berkeley-db@5 libsamplerate cmake pkg-config
```

The release bundle currently includes the receiver and its Homebrew libraries, so `make build` requires a `scream` executable at the repository root even if you only intend to use Direct Routing.

Build the receiver out of tree, using the upstream `JACK_ENABLE` CMake option:

```bash
git clone https://github.com/duncanthrax/scream.git
cd scream

cmake -S Receivers/unix -B Receivers/unix/build \
  -DJACK_ENABLE=ON \
  -DPULSEAUDIO_ENABLE=OFF \
  -DALSA_ENABLE=OFF \
  -DPCAP_ENABLE=OFF \
  -DSNDIO_ENABLE=OFF
cmake --build Receivers/unix/build --parallel

cp Receivers/unix/build/scream /path/to/scream-macos/scream
```

The upstream build can silently disable an unavailable optional output. Verify that the copied executable is linked to JACK before packaging it:

```bash
otool -L /path/to/scream-macos/scream | grep libjack
```

## Build and install

From the repository root:

```bash
# Run the SwiftPM executable for UI or Scream-mode development.
make dev-run

# Build the ad-hoc signed release bundle.
make build
open .build/release/ScreamBar.app

# Build and install the bundle in /Applications.
make install
open /Applications/ScreamBar.app
```

The packaging recipe defaults to the Apple silicon Homebrew prefix, `/opt/homebrew`. Override it when Homebrew uses another prefix:

```bash
make HOMEBREW_PREFIX="$(brew --prefix)" build
```

## Usage

Click the speaker icon in the menu bar, open **Settings**, and select **Scream** or **Direct Routing** under **Application Mode**. Changing the mode stops the previous mode before the new one can start. Settings are saved automatically.

The controls common to both modes are:

- **Auto-start** starts the selected mode when ScreamBar launches.
- **Launch at login** registers the application as a macOS login item.
- **Global Shortcut** toggles the selected mode.
- **USB Device Trigger** starts or stops the selected mode when the configured USB device connects or disconnects.

### Scream

The Status tab controls JACK and the Scream receiver individually or together. Settings include:

- multicast or unicast reception;
- the UDP port used in unicast mode (4010 by default);
- an optional JACK nominal sample rate;
- an optional JACK buffer size from 64 to 2048 frames;
- whether the main toggle controls only Scream or both Scream and JACK.

`---` leaves the corresponding JACK value at the `jackd` default. JACK audio changes apply on its next start.

The Scream receiver listens for network audio. On first use, allow incoming connections if the macOS firewall prompts for the bundled `scream` executable. The firewall permission is only relevant to Scream mode.

If JACK is already running, ScreamBar detects it and does not take ownership of that external process.

### Direct Routing

Select an input, an output, and a buffer policy, then start Direct Routing from the Status tab.

The first output choice is **System Default**. An explicitly selected output is stored by CoreAudio device UID. If it disconnects, ScreamBar temporarily routes to the current system default and returns to the preferred output when it becomes available again. The saved preference is not overwritten by the fallback. Fallback only applies when the preferred output is unavailable; a present but incompatible device reports its routing error. An explicitly selected input does not silently fall back; the route waits for that input to return.

Available buffer choices are **Automatic**, 64, 128, 256, 512, 1024, and 2048 frames:

- **Automatic** leaves the devices' buffer sizes unchanged.
- An explicit value must be supported by both devices. ScreamBar applies and verifies it before starting, then restores the previous values when the route stops unless another client changed them in the meantime.
- Smaller buffers can reduce the CoreAudio portion of latency but increase the risk of dropouts. Bluetooth transport latency remains independent of this setting; Automatic is recommended for Bluetooth devices.

Bluetooth outputs follow the same generic CoreAudio negotiation path and are best-effort. No Bluetooth-specific workaround is applied.

#### Sample-rate compatibility

Direct Routing V1 does not perform software sample-rate conversion. The input and output hardware must support a common nominal sample rate. ScreamBar chooses one deterministically in this order:

1. the output device's active nominal rate, if supported by the input;
2. 48 kHz;
3. 44.1 kHz;
4. another common rate in deterministic order.

If the devices do not share a nominal rate, the route stops with `The selected devices do not share a nominal sample rate`. Choose another input or output, or configure the devices externally to expose a common rate. Drift compensation keeps clocks synchronized; it is not sample-rate conversion.

#### CoreAudio behavior

For a full-duplex physical device, Direct Routing uses one AUHAL bound directly to that device. For different input and output devices, it creates a process-private Aggregate Device, keeps the output as its master clock, and enables drift compensation only for the input subdevice. If either device cannot participate in that private Aggregate Device, V1 fails cleanly; it does not fall back to a two-AUHAL architecture.

The route remains in shared mode:

- it does not request Hog Mode or exclusive access;
- it does not change the macOS system default output;
- other clients such as music and voice-chat applications can continue to use the physical output.

The playthrough uses one AUHAL in one clock domain, with input IO on element 1 and output IO on element 0. It prefers the native AUHAL software-playthrough connection with a deterministic Float32 client PCM format. CoreAudio may convert normal PCM representation or interleaving, but the client format uses the negotiated hardware rate and never hides a nominal-rate mismatch. If channel mapping requires it, a render callback pulls AUHAL input through preallocated buffers. Direct Routing V1 does not use an application-level ring buffer.

Device, default-device, alive/hot-plug, nominal-rate, and buffer changes are monitored. A change affecting the active route performs a complete stop, AUHAL disposal, Aggregate Device destruction, resolution, renegotiation, rebuild, and restart. A running Aggregate Device is never mutated in place.

## Status and logs

The Status tab reports stopped, starting, running, reconfiguring, waiting, and error states as appropriate for the selected mode.

The Logs tab contains application, JACK, Scream, and Direct Routing messages. Use **Clear** to reset the in-memory log.

ScreamBar stops active audio resources before system sleep and rebuilds the previously running mode after wake. Direct Routing also rebuilds when an effective device or hardware format changes.

## Tests

Run unit and contract tests with:

```bash
swift test
```

CoreAudio hardware integration tests are opt-in because they open real input/output devices and temporarily exercise supported buffer settings. Quit ScreamBar first so it does not own a competing route, grant microphone permission to the process running the tests if macOS asks, then run:

```bash
SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS=1 \
  swift test --filter CoreAudioCoexistenceIntegrationTests
```

The regular suite covers IO topology and stream-format contracts. The hardware integration suite covers single-AUHAL creation, explicit buffer application and restoration, preservation of the default output and Hog Mode state, and concurrent use by a normal macOS audio client. A hardware-dependent test is skipped when the machine does not expose a suitable device or buffer configuration.

## Troubleshooting

### Audio-input permission is denied

Enable ScreamBar under **System Settings → Privacy & Security → Microphone**, then start Direct Routing again. Use the `.app` bundle rather than `swift run` when validating permission behavior.

### The devices do not share a nominal sample rate

The selected pair has no hardware rate in common. Direct Routing V1 fails cleanly instead of resampling. Select another input or output. A wired or USB input often exposes more compatible rates than the microphone profile of a Bluetooth headset.

### A buffer size is unsupported or cannot be configured

Choose **Automatic** or another frame count supported by both devices. Very small values are not available on every device and can be rejected while another audio client is active.

### A preferred device is unavailable

An unavailable preferred output uses **System Default** temporarily and is restored automatically when it returns. An unavailable explicit input remains selected and Direct Routing waits for it instead of capturing a different input.

### Bluetooth latency is still high

The frame setting only changes CoreAudio buffering where the device permits it. It cannot remove the latency introduced by the Bluetooth transport and codec. Use a wired, USB, or built-in output when consistently low monitoring latency is required.

## License

See [LICENSE](LICENSE).
