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
- **USB Device Trigger** starts or stops the selected mode when the configured USB device connects or disconnects. Optional Bash commands can run before USB-triggered startup and after USB-triggered shutdown; a failed start command prevents audio startup, while a failed stop command is logged without blocking shutdown.

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

For implementation details, latency accounting, runtime metrics, teardown rules, and the debugging/soak-test playbook, see [Direct Routing architecture](docs/direct-routing.md).

The first output choice is **System Default**. An explicitly selected output is stored by CoreAudio device UID. If it disconnects, ScreamBar temporarily routes to the current system default and returns to the preferred output when it becomes available again. The saved preference is not overwritten by the fallback. Fallback only applies when the preferred output is unavailable. An explicitly selected input does not silently fall back; the route waits for that input to return.

Available buffer choices are **Automatic**, 64, 128, 256, 512, 1024, and 2048 frames:

- **Automatic** leaves synchronized routes at the devices' current buffer sizes. When asynchronous sample-rate conversion is required, it starts with the smallest common supported tier from 64, 128, 256, and 512 frames. It can rebuild at the next tier after a runtime disruption.
- An explicit value must be supported by both devices. ScreamBar applies and verifies it before starting, then restores the previous values when the route stops unless another client changed them in the meantime.
- Smaller buffers can reduce the CoreAudio portion of latency but increase the risk of dropouts. If an automatic tier is rejected during configuration, ScreamBar tries the next tier. Bluetooth transport latency remains independent of this setting; Automatic is recommended for Bluetooth devices.

Bluetooth outputs follow the same generic CoreAudio negotiation path and are best-effort. No Bluetooth-specific workaround is applied.

#### Automatic sample-rate negotiation and conversion

There is no manual sample-rate setting for Direct Routing. When the input and output support a common hardware nominal rate, ScreamBar chooses it deterministically in this order:

1. the output device's active nominal rate, if supported by the input;
2. 48 kHz;
3. 44.1 kHz;
4. another common rate in deterministic order.

When no common nominal rate exists, ScreamBar keeps both devices at valid native rates and automatically converts between them. For example, a 48 kHz S/PDIF receiver can route to a 44.1 kHz Bluetooth output without changing either device to an unsupported rate. The running status displays both rates when conversion is active.

The output device remains the timing master. Conversion uses Apple's Varispeed audio unit at high quality, a preallocated lock-free single-producer/single-consumer buffer, and adaptive clock correction. The audio render callbacks allocate no memory, acquire no locks, and emit no logs. The adaptive correction is required because two physical devices have independent clocks; fixed-ratio sample-rate conversion alone would eventually underrun or overflow.

The converter targets no more than 5 ms of app-added latency. Its FIFO may grow only as needed within a 10 ms low-latency ceiling to absorb callback phase, clock drift, and scheduling jitter. If a device combination cannot operate reliably inside that ceiling, ScreamBar uses the existing last-resort fallback and displays its calculated latency instead of a fixed estimate. This value excludes latency inside the physical input, output, codec, or Bluetooth transport.

Automatic mode also monitors callback-size violations, callback deadline misses, underruns, overflows, and FIFO resynchronization. A disrupted converted route is rebuilt at the next buffer tier actually supported by both devices. If no safer shared tier exists, the route stops with a contextual error instead of retrying unsupported sizes. Route logs include the configured buffer policy and effective tier, and distinguish an unstable explicit setting from an exhausted Automatic ladder.

#### CoreAudio behavior

For a full-duplex physical device, Direct Routing uses one AUHAL bound directly to that device. For different devices that share a nominal rate, it creates a process-private Aggregate Device, keeps the output as its master clock, and enables drift compensation only for the input subdevice. If the devices have no common nominal rate, Direct Routing instead uses one input AUHAL and one output AUHAL with the automatic asynchronous converter between them; no Aggregate Device is created for that route.

The route remains in shared mode:

- it does not request Hog Mode or exclusive access;
- it does not change the macOS system default output;
- other clients such as music and voice-chat applications can continue to use the physical output.

The synchronized playthrough uses one AUHAL in one clock domain, with input IO on element 1 and output IO on element 0. It prefers the native AUHAL software-playthrough connection with a deterministic Float32 client PCM format. CoreAudio may convert normal PCM representation or interleaving, but the client format uses the negotiated hardware rate. The asynchronous path uses separate deterministic Float32 formats at the input and output native rates, with conversion performed explicitly between them.

Device, default-device, alive/hot-plug, nominal-rate, and buffer changes are monitored, and every change still refreshes the published CoreAudio inventory and hardware revision. Direct Routing rebuilds only when the effective input/output or one of their relevant capabilities changes. Adding or removing an unrelated device, such as an unused HDMI display, does not interrupt the active route. A system-default output change is also ignored while an available explicit output remains effective; it does rebuild a `System Default` route or an explicit-output fallback. Losing an explicit output, following a changed fallback, restoring the preferred output, or changing an active endpoint's rate, channel, alive, or buffer properties performs a complete stop, AUHAL disposal, Aggregate Device destruction, resolution, renegotiation, rebuild, and restart. A running Aggregate Device is never mutated in place.

## Status and logs

The Status tab reports stopped, starting, running, reconfiguring, waiting, and error states as appropriate for the selected mode.

The Logs tab contains application, JACK, Scream, and Direct Routing messages. Its source menu can show all messages or any subset of those sources. Use **Clear** to reset the in-memory log.

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

The automatic converter has a separate hardware test. By default it looks for `Cubilux SPDIF Receiver` and `Bose QC 45`; override either name for another incompatible pair:

```bash
SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=60 \
  swift test --filter CoreAudioAsyncSRCIntegrationTests
```

The simulated converter soaks are opt-in and can be run independently. The value is a wall-clock duration in seconds:

```bash
SCREAMBAR_ASYNC_SRC_TIMING_SOAK_SECONDS=300 \
  swift test --filter testAdaptiveCallbackMatrixDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_QUALITY_SOAK_SECONDS=300 \
  swift test --filter testAdaptiveRoutingQualityDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_FALLBACK_QUALITY_SOAK_SECONDS=300 \
  swift test --filter testFallbackRoutingQualityDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_PERFORMANCE_SOAK_SECONDS=300 \
  swift test --filter testConversionMatrixKeepsRealtimePerformanceHeadroomDuringRequestedSoak
```

Use `60`, `300`, `900`, `1800`, or `3600` seconds for the standard 1, 5, 15, 30, or 60 minute stages. Run the shorter stages first; the long hardware soak is intended only after the regular suite and simulated stages pass.

The regular suite covers rate planning, independent-clock drift up to ±1000 ppm, jitter and burst simulation, lock-free buffer behavior, pitch/gain/SNR, IO topology, callback deadlines, and stream-format contracts. The hardware suites cover both playthrough paths, the complete Direct Routing service lifecycle, cleanup, explicit buffer application and restoration, preservation of the default output and Hog Mode state, and concurrent use by a normal macOS audio client. A hardware-dependent test is skipped when the requested devices or capabilities are unavailable.

The final one-hour CoreAudio matrix is separately opt-in. It covers a stable
converted route, prolonged silence followed by audio resume, high CPU load,
System Default output changes, Cubilux disconnect/reconnect, and a
48 kHz → other state → 48 kHz cycle. The last four require an operator; run all
hardware scenarios sequentially after quitting ScreamBar.

```bash
SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourNormalConvertedRoute
```

Each run writes a JSON report under `.build/coreaudio-soak-reports` with
aggregate FIFO fill, SRC ratio, observed latency, configured latency ceiling,
callback gap/execution time, rebuild, error, underrun/overrun, and
execution-deadline telemetry. Intentional interruption scenarios classify
earlier-session health events separately and require the recovered final
session to be clean. The callback accumulates the new statistics without
locks, allocations, or logging and publishes one coherent atomic snapshot
every 64 output callbacks. See
[Direct Routing architecture](docs/direct-routing.md#one-hour-scenario-matrix)
for every command, operator instruction, environment override, metric
definition, and real-time telemetry constraint.

## Troubleshooting

### Audio-input permission is denied

Enable ScreamBar under **System Settings → Privacy & Security → Microphone**, then start Direct Routing again. Use the `.app` bundle rather than `swift run` when validating permission behavior.

### Sample-rate conversion is active

This is expected when the input and output have no hardware nominal rate in common. ScreamBar displays the input and output rates and converts automatically. Conversion itself is sub-millisecond on supported Apple hardware, but at least one device buffer is required to bridge independent clocks. ScreamBar targets 5 ms of app-added latency, permits an adaptive stability margin up to 10 ms, and reports a calculated fallback value when that ceiling cannot be maintained. Bluetooth codec/transport latency is independent and usually much larger.

### A buffer size is unsupported or cannot be configured

Choose **Automatic** or another frame count supported by both devices. Very small values are not available on every device and can be rejected while another audio client is active.

### A preferred device is unavailable

An unavailable preferred output uses **System Default** temporarily and is restored automatically when it returns. An unavailable explicit input remains selected and Direct Routing waits for it instead of capturing a different input.

### Bluetooth latency is still high

The frame setting only changes CoreAudio buffering where the device permits it. It cannot remove the latency introduced by the Bluetooth transport and codec. Use a wired, USB, or built-in output when consistently low monitoring latency is required.

## License

See [LICENSE](LICENSE).
