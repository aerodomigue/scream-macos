# Direct Routing architecture

This document describes the implemented CoreAudio route, its asynchronous
sample-rate converter (SRC), the latency value shown by ScreamBar, and the
diagnostic workflow used to change it safely.

## Design invariants

Direct Routing follows these rules:

- Prefer a synchronized hardware route whenever the devices expose a common
  nominal sample rate. Asynchronous SRC is used only when the intersection is
  empty.
- The selected output is the timing master. The output callback decides when
  audio is consumed in the converted route.
- Never request Hog Mode, make a device exclusive, or change the macOS system
  default merely to create a route.
- Never use Bluetooth-specific behavior. Bluetooth devices use the same
  negotiation and conversion paths as every other CoreAudio device.
- Keep CoreAudio and Audio Unit details behind `CoreAudioDeviceService` and the
  `CoreAudioBackend` abstraction.
- Allocate all buffers and callback state before starting. The real-time C
  callbacks do not allocate memory, acquire locks, or log.
- Hardware inventory changes are always published, but only a change that
  affects the effective route causes a rebuild. A running Audio Unit or
  Aggregate Device is not modified in place.
- A stop is complete only when all Audio Units, callbacks, render contexts,
  Aggregate Devices, and pending route registrations have been released.

## Selection and nominal-rate planning

`CoreAudioDeviceService` resolves the saved selection against a fresh hardware
snapshot before it negotiates rates.

- `System Default` remains a symbolic preference and always resolves to the
  current `kAudioHardwarePropertyDefaultOutputDevice`.
- An explicit output UID temporarily falls back to the system default while it
  is absent, without replacing the saved UID. The preferred device is restored
  when it returns.
- An absent explicit input does not fall back silently; the route waits for it.

`NominalSampleRateNegotiator` normalizes each device's advertised ranges and
calculates their intersection. A common rate is selected in this order:

1. the output's current nominal rate;
2. 48 kHz;
3. 44.1 kHz;
4. the deterministic candidate nearest 48 kHz, with the lower rate as the
   tie-breaker.

If a common rate exists, both physical devices are set to that rate and the
write is verified before the route is created. Drift compensation does not
replace this negotiation and is not sample-rate conversion.

If the intersection is empty, each device keeps a valid independent rate. Its
current nominal rate is preferred, followed by 48 kHz, 44.1 kHz, and the same
deterministic range selection. This produces
`AudioSampleRatePlan.converted(inputSampleRate:outputSampleRate:)` and enables
the asynchronous path. SRC is therefore a compatibility fallback, not the
default route.

## Synchronized topology

When the same full-duplex device is selected for input and output, one AUHAL is
bound directly to it. When different devices share the negotiated rate,
ScreamBar first creates a process-private Aggregate Device:

```text
input device -- drift compensation ON --\
                                        private Aggregate Device -> one AUHAL
output device -- master, drift OFF -----/
```

The aggregate membership, nominal rate, output master, and drift flags are read
back and verified. A device that cannot participate in the private aggregate
causes a contextual failure; it does not silently select the converted route,
because the converted route is selected solely by nominal-rate compatibility.

The AUHAL has input IO enabled on element 1 and output IO enabled on element 0.
The client side uses non-interleaved native-endian Float32 PCM at the negotiated
hardware rate. For equal channel counts, ScreamBar first attempts the native
software-playthrough connection:

```text
AUHAL output scope / element 1 -> AUHAL input scope / element 0
```

If that connection is unavailable or channel mapping differs, one render
callback pulls input with `AudioUnitRender()` using preallocated memory. This is
still one AUHAL in one clock domain; the synchronized path does not use the
asynchronous FIFO.

## Converted topology

Different nominal rates require two physical clock domains:

```text
input device
  -> input AUHAL callback
  -> lock-free SPSC FIFO (Float32)
  -> Apple Varispeed source callback
  -> Apple Varispeed SRC (high quality)
  -> output AUHAL callback
  -> output device / master clock
```

The input AUHAL has input IO enabled and output IO disabled. The output AUHAL
has output IO enabled and input IO disabled. Both client formats are
non-interleaved native-endian Float32 PCM, at their respective hardware rates.
Varispeed consumes the input-rate format and produces the output-rate format.
Normal PCM representation and interleaving conversion must not be confused
with nominal sample-rate conversion.

The output AUHAL starts first and produces silence while the FIFO primes; the
input AUHAL starts second. Starting output first establishes the output as the
consumer clock and lets input-start failure roll the output start back cleanly.

The FIFO is single-producer/single-consumer. Its sample storage, AudioBufferList,
input scratch memory, source scratch memory, controller, and telemetry are
allocated before initialization. The build asserts that the integer atomics
used by the callback path are always lock-free on the target platform.

Channel mapping is deterministic: matching channel indexes are copied, mono
input is duplicated to the first two output channels, and unmapped output
channels are silent.

## Independent-clock correction

Fixed-ratio conversion alone is insufficient because the nominal rates do not
describe the small frequency error between two physical clocks. Without
feedback, the FIFO would eventually underrun or overflow.

The output callback samples FIFO occupancy and updates the Varispeed playback
rate. The controller smooths fill error and rate changes, applies a dead band,
and clamps correction to +/-0.15% (`0.0015`, or +/-1500 ppm). At automatic
64- and 128-frame tiers it uses the faster adaptive controller. Larger
256- and 512-frame tiers use a slower conservative controller intended as a
last-resort stability mode.

This correction is deliberately small: it compensates clock drift and FIFO
phase, while Apple Varispeed performs the actual nominal-rate conversion.

## Automatic buffers and FIFO target

For a synchronized route, `Automatic` leaves the device buffer sizes unchanged.
For a converted route, `AsyncSRCLowLatencyPolicy` selects the first frame count
supported by both devices from:

```text
64 -> 128 -> 256 -> 512 frames
```

An explicit setting is validated on both devices. ScreamBar applies and reads
it back, then restores the previous value on stop unless another client changed
the value in the meantime.

The route buffer tier and the FIFO fill target are separate controls:

- The route tier changes only through a full stop/rebuild/start cycle.
- The FIFO target can move while the same route is running; no allocation or
  FIFO capacity resize occurs.

The initial target accounts for the input callback quantum, the output quantum
converted to input-rate frames, Apple Varispeed lookahead, and a 0.5 ms
scheduling reserve. During startup, ScreamBar initially assumes 33 output
frames of converter lookahead. After Varispeed is initialized, it reads
`kAudioUnitProperty_Latency`. If the measured value changes sizing, ScreamBar
uninitializes the provisional units, removes their callbacks, releases the
provisional context, and rebuilds it before the route starts. This bounded
startup-only context rebuild is not a live FIFO resize.

While running, the target adapts as follows:

- Low-water pressure grows the target by half the observed input quantum,
  capped by the 10 ms low-latency budget.
- An underrun unprimes the route, resets clock control, and grows the target
  more aggressively, still capped by the calculated maximum target.
- After 60 seconds of uninterrupted output, an elevated target is reduced by
  approximately one converted output quantum, never below its initial value.
- Data beyond the fixed readable-frame ceiling is not allowed to grow latency
  without bound. It is dropped and recorded as a ceiling/overflow event.

Consequently, a displayed latency moving from 4.0 ms to 4.2 or 4.3 ms and later
returning can be normal FIFO occupancy or target adaptation. It does not, by
itself, mean that the hardware buffer tier or allocated FIFO was resized.

### Low-latency and fallback budgets

The preferred goal is at most 5 ms of app-added latency. The hard low-latency
ceiling is 10 ms. A configuration is classified as low latency only when its
safe target and maximum readable occupancy fit that ceiling.

If the callback geometry cannot fit mathematically, the fallback target is
computed from two input quanta, one converted output quantum, and Varispeed
lookahead. The maximum target is twice that value. The status reports the
calculated result and labels the route as a low-latency fallback; it never
substitutes a fixed placeholder such as 34 ms.

## Meaning of `app approximately N ms`

The Status view is refreshed by a 500 ms monitor. For converted routes, the
displayed estimate is:

```text
effective occupancy = max(
  target fill + max(configured input quantum, observed input quantum) / 2,
  current readable FIFO frames
)

app estimate = effective occupancy / input sample rate
             + measured Varispeed latency
```

This is an estimate of buffering and converter latency inside ScreamBar's
asynchronous bridge. It includes FIFO occupancy, half an effective input
callback quantum, and Apple Varispeed's reported algorithmic latency.

It does **not** include:

- latency before samples reach CoreAudio from the physical/virtual input;
- input hardware, driver, or S/PDIF receiver latency;
- output driver and hardware buffering outside the app;
- DAC, headset, codec, radio, or Bluetooth transport latency;
- acoustic propagation.

It is therefore the app contribution requested for comparing future devices,
not a microphone-to-ear loopback measurement. An external loopback measurement
is required for total end-to-end physical latency.

## Monitoring, escalation, and route rebuilds

The real-time context exposes atomic counters and maxima. `LegacyCoreAudioBackend`
turns the following runtime conditions into buffer-escalation reasons:

- input or output render errors;
- failure to update the Varispeed playback-rate parameter;
- a write above the FIFO latency ceiling, FIFO overflow, or dropped input;
- FIFO resynchronization or an underrun after the target reached its ceiling;
- input or output callback frame-limit violation;
- a callback larger than the configured device quantum;
- callback execution that reaches or exceeds its real-time frame deadline.

Telemetry also records captured/rendered/priming frames, startup trims, current
and maximum target/readable frames, callback sizes and gaps, maximum callback
execution times, current/maximum playback-rate deviation, source request sizes,
and last input/output OSStatus.

The long-run fields are collected without putting reporting work in the audio
thread:

- FIFO fill is sampled at entry to every valid output callback, including the
  priming period. Rejected callbacks are excluded.
- FIFO sample count/sum/min/max and SRC ratio adjustment count/min/max are
  accumulated in plain single-writer fields owned by the output callback.
- A coherent C11 seqlock snapshot is published every 64 output callbacks. One
  batch uses two generation updates and eight relaxed payload stores, averaging
  about 0.156 atomic operations per callback.
- A ratio adjustment means a change greater than the controller's `1e-6`
  deadband; repeated writes of the same effective value are not counted.
- The new batched FIFO and ratio accumulators saturate instead of wrapping and
  expose `telemetrySaturated` if a session exceeds their representable range.
- The final partial batch is flushed only after the output AUHAL has confirmed
  it is stopped. The backend forwards that final snapshot before removing the
  route, so a rebuild cannot hide the previous session's last counters.
- Observed estimated-latency min/max, the configured latency ceiling, and
  routing state/rebuild counts are sampled and aggregated on the non-real-time
  test thread.

No allocation, lock, log, ARC operation, or sequentially consistent atomic was
added to either audio callback. CoreAudio does not expose a reliable native
xrun counter for this topology, so reports keep underruns, overruns,
latency-ceiling overruns, resynchronizations, dropped frames, and callback
deadline misses separate instead of inventing an ambiguous total.

In `Automatic`, the sensitivity policy decides when runtime disruption reaches
the rebuild threshold:

- `Strict` rebuilds after the first new actionable incident.
- `Relaxed` is the default. It tolerates three recovered disruption episodes in
  a rolling 10-second monotonic window and rebuilds on the fourth.

The policy consumes monotonic counter deltas rather than log messages or raw
monitor polls. Multiple overflow/underrun callbacks in one uninterrupted burst
are coalesced into one episode. One complete monitor interval (approximately
500 ms) without a new low-level incident closes that episode and checkpoints
the policy-facing counters. A new disruption after recovery starts the next
episode. Continuous counter growth for two seconds is classified as persistent
instability and rebuilds without manufacturing several episodes from the same
burst. Dropped-frame volume is not itself an event count; its associated
ceiling-overflow or FIFO-overflow counter opens the episode. Changing
sensitivity resets only the policy window and does not rebuild the running
route.

Once the threshold is reached, a 64-frame route can move to 128, then 256, then
512. Unsupported tiers are skipped. A configuration-time buffer rejection
similarly tries the next tier.
If no safer tier exists, or an explicit tier is unstable, Direct Routing stops
with `latencyStabilityLimitExceeded` rather than looping forever.

The `Direct Routing active` log records both the configured policy (`automatic`
or `explicit N frames`) and the effective tier. A terminal stability log then
distinguishes these cases:

- an explicit setting became unstable, so ScreamBar does not override the
  user's selected frame count;
- the Automatic ladder was exhausted after all supported safer tiers were
  attempted.

Both messages include the effective tier, calculated current and maximum app
latency, and semantic escalation reasons/counters.

The automatic override is scoped to the effective input/output UIDs and their
nominal rates. Changing that identity clears the override so the new route can
start again from its smallest supported tier.

CoreAudio listeners cover device inventory, default input/output, device alive
state, nominal rate, buffer frame size/range, and stream configuration. Every
observed hardware change refreshes the published inventory and increments its
revision. Rapid events are debounced/coalesced before Direct Routing compares a
new effective-route signature with the active one.

That signature contains only the effective input/output UIDs, fallback state,
channel counts, alive state, and current nominal rates. Advertised rate ranges
and buffer metadata are still published to the UI, but a volatile metadata
change cannot invalidate a stream that is already running. The route therefore
remains running when only an unselected device is added or removed (for
example, a non-default audio device or an unused HDMI display). It also remains
running when macOS changes the default output while the user's explicit
preferred output is still present and effective.

macOS can pause CoreAudio callbacks briefly while it enumerates unrelated
hardware. For an inventory revision whose effective-route signature is
unchanged, ScreamBar keeps the existing Audio Units open and starts a two-second
recovery window. Runtime disruptions observed in that window remain in the raw
soak telemetry, but a stability checkpoint prevents those cumulative counters
from triggering a later buffer escalation. New errors after the checkpoint are
still evaluated normally. Callback sizes larger than the requested hardware
quantum affect the calculated latency but only an actual preallocated frame
limit violation is an escalation reason.

A rebuild is still required when:

- a `System Default` selection resolves to a different default endpoint;
- a preferred explicit output disappears and activates fallback;
- the default changes while an explicit-output fallback is active;
- the preferred explicit output returns and replaces its fallback;
- an effective input/output endpoint disappears or changes a signature
  property such as channels, alive state, or current nominal rate.

`System Default` is resolved again during the rebuild rather than replaced by a
persisted concrete UID. Likewise, explicit fallback never overwrites the saved
preferred UID.

Every effective device, nominal-rate, channel-layout, or alive-state change follows:

```text
stop -> remove callbacks -> uninitialize -> dispose Audio Units
     -> destroy private aggregate (if any) -> restore owned buffer changes
     -> refresh/resolve -> renegotiate -> prepare -> validate -> start
```

The old route is gone before the replacement is started. Listener cleanup for a
device that has already disappeared is terminal and cannot block publication of
the new snapshot. Other listener-removal failures remain registered for bounded
retry.

## Teardown and ownership

Synchronized teardown stops and uninitializes the AUHAL, disposes it, then
releases its callback context. Converted teardown independently attempts to:

1. stop input AUHAL, then output AUHAL;
2. remove input, output, and Varispeed-source callbacks;
3. uninitialize input AUHAL, output AUHAL, and Varispeed;
4. dispose each Audio Unit;
5. release the render context only after every callback is invalidated;
6. destroy the Aggregate Device for synchronized multi-device routes;
7. restore buffer sizes owned by the route.

Failures retain the affected resource in the route registry so cleanup can be
retried. The service does not report `.stopped`, and the mode coordinator does
not start Scream/JACK, until `confirmRouteResourcesReleased()` succeeds. This
barrier is also what releases the microphone privacy indicator after leaving
Direct Routing.

## Permissions and coexistence

Microphone/audio-input permission is requested lazily when Direct Routing is
actually started. Scream mode does not open Direct Routing's input AUHAL, and
ScreamBar never requests system-audio-capture permission for this feature.

All routes remain normal shared CoreAudio clients. ScreamBar does not read or
write Hog Mode and does not mutate the default output. Music, voice-chat, and
other macOS clients should remain able to use the selected output concurrently.

## Debugging guide

Useful semantic logs include route selection, the two nominal rates, configured
buffer policy, effective tier, calculated latency class, escalation reason,
hardware/default changes, and every teardown stage. Backend debug logs retain
decoded OSStatus and FourCC details where available. Ignored hardware revisions
are debug-only and explicitly state that active endpoints and capabilities did
not change; they should not be accompanied by teardown logs.

When investigating a problem, preserve at least:

- input/output names and UIDs;
- advertised/current nominal rates and buffer ranges;
- selected buffer policy and effective tier;
- the complete `Direct Routing active` line;
- every `increasing the automatic buffer` reason;
- all teardown lines through `teardown complete`;
- the final metric snapshot from an integration failure.

Interpret common symptoms as follows:

- A small changing `app approximately` value with clean metrics usually reflects normal FIFO
  occupancy/target adaptation.
- A tier change is always accompanied by an explicit rebuild log.
- `primingSilenceFrames` and startup trims are expected only around startup;
  runtime resynchronization, overflow, dropped input, deadline misses, or
  ceiling underruns are not hidden as startup events.
- A stable converted route should keep its session identity for an entire soak.
  Any reconfiguration, stop, wait state, or identity change is a failure in the
  hardware service soak.

## Test matrix

Run the regular suite first:

```bash
swift test
```

The regular suite includes nominal-rate planning, buffer sizing, lock-free FIFO
behavior, clock drift/jitter/burst simulations, real-time deadline telemetry,
channel mapping, Float32 stream contracts, Apple Varispeed quality and
performance, callback-to-FIFO-to-converter end-to-end tests, lifecycle rollback,
teardown, hardware reconciliation, and mode-transition barriers.

### Simulated soaks

The four soak entry points are independent:

```bash
SCREAMBAR_ASYNC_SRC_TIMING_SOAK_SECONDS=60 \
  swift test --filter testAdaptiveCallbackMatrixDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_QUALITY_SOAK_SECONDS=60 \
  swift test --filter testAdaptiveRoutingQualityDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_FALLBACK_QUALITY_SOAK_SECONDS=60 \
  swift test --filter testFallbackRoutingQualityDuringRequestedSoak

SCREAMBAR_ASYNC_SRC_PERFORMANCE_SOAK_SECONDS=60 \
  swift test --filter testConversionMatrixKeepsRealtimePerformanceHeadroomDuringRequestedSoak
```

Use this incremental duration ladder:

| Stage | Environment value |
| --- | ---: |
| 1 minute | `60` |
| 5 minutes | `300` |
| 15 minutes | `900` |
| 30 minutes | `1800` |
| 60 minutes | `3600` |

Do not treat four parallel simulated processes as a substitute for the hardware
test. Parallel runs intentionally add scheduler pressure; hardware validation is
best run alone so competing test processes do not contaminate the audio result.

### Cubilux hardware loopback latency

The dedicated loopback test measures the complete external path independently
of Direct Routing:

```text
Mac CoreAudio output -> Cubilux TX -> TOSLINK -> Cubilux RX -> Mac CoreAudio input
```

It opens one output-only AUHAL and one input-only AUHAL at their unchanged
current nominal rate. It does not create an Aggregate Device, run the SRC/FIFO,
change a hardware buffer, request Hog Mode, or change a macOS default device.
Signal detection uses normalized chirp correlation. Because the two USB devices
have independent sample clocks, their timelines are aligned using CoreAudio
`mHostTime`; device-local `mSampleTime` values are never compared directly.

```bash
SCREAMBAR_RUN_CUBILUX_LOOPBACK_TESTS=1 \
  swift test --filter CoreAudioCubiluxLoopbackIntegrationTests
```

The default endpoints are output `USB SPDIF Adapter` and input
`Cubilux SPDIF Receiver`. Override names with
`SCREAMBAR_CUBILUX_LOOPBACK_OUTPUT_NAME` and
`SCREAMBAR_CUBILUX_LOOPBACK_INPUT_NAME`, or use the corresponding `_UID`
variables for an exact match. `SCREAMBAR_CUBILUX_LOOPBACK_ITERATIONS` controls
the repeated marker count. Reports under `.build/coreaudio-soak-reports`
contain every accepted sample offset, min/median/p95/max/range, missed or
ambiguous markers, signal peak/RMS/clipping, physical ASBDs, and callback error
telemetry. The result includes HAL and USB buffering around both adapters; it is
not the intrinsic latency of TOSLINK conversion alone.

### Hardware route

Quit ScreamBar before the integration run so the test owns the route. The test
defaults to the Cubilux/Bose pair, and names can be overridden:

```bash
SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=60 \
  swift test --filter CoreAudioAsyncSRCIntegrationTests
```

For the final 60-minute service soak, select only the long-running lifecycle
test so the one-second construction smoke test does not obscure its timing:

```bash
SCREAMBAR_RUN_COREAUDIO_INTEGRATION_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testDirectRoutingServiceSoakKeepsConvertedRouteHealthyAndTearsDown
```

The hardware soak samples state every 500 ms, rejects session identity changes,
observes one additional 600 ms monitor window at the deadline, then verifies
complete teardown. It requires a real incompatible input/output pair and may be
skipped when the named devices or capabilities are not present.

### One-hour scenario matrix

The final matrix is opt-in separately so enabling the ordinary hardware tests
cannot accidentally start six hour-long runs. Its default duration is 3600
seconds; `SCREAMBAR_ASYNC_SRC_SOAK_SECONDS` can select the incremental 60, 300,
900, 1800, and 3600-second stages. Quit ScreamBar first and run hardware cases
sequentially because they share the same CoreAudio devices.

The unattended stable-route cases are:

```bash
SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourNormalConvertedRoute

SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_INPUT_NAME="Cubilux SPDIF Receiver" \
SCREAMBAR_ASYNC_SRC_OUTPUT_NAME="Bose QC 45" \
SCREAMBAR_ASYNC_SRC_CPU_LOAD_WORKERS=8 \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourConvertedRouteUnderHighCPULoad
```

Omit `SCREAMBAR_ASYNC_SRC_CPU_LOAD_WORKERS` to use all active CPU cores except
two. The worker pool is always stopped during test cleanup.

The four cases below require an operator, so they additionally require
`SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS=1`:

```bash
SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourSilenceThenResumeConvertedRoute

SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourFollowsCoreAudioDefaultOutputChanges

SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourCubiluxDisconnectReconnect

SCREAMBAR_RUN_COREAUDIO_LONG_SOAK_TESTS=1 \
SCREAMBAR_RUN_COREAUDIO_OPERATOR_SOAK_TESTS=1 \
SCREAMBAR_ASYNC_SRC_SOAK_SECONDS=3600 \
  swift test --filter testOneHourInputRateCyclesFrom48KHzAndBack
```

The operator instructions are logged at test start. The silence test requests
an audible reference for the first 10%, silence from 10% through 80%, and the
same signal again for the final 20%. It proves transport continuity and reports
callback health; it deliberately does not calculate signal amplitude in the
real-time callback, so the operator confirms actual silence and audible resume.
The default-output case requires at least two effective changes by default;
override that with `SCREAMBAR_ASYNC_SRC_MINIMUM_OUTPUT_CHANGES`.

Every run writes a timestamped JSON report to
`.build/coreaudio-soak-reports` (or
`SCREAMBAR_ASYNC_SRC_SOAK_REPORT_DIRECTORY`). Reports aggregate finalized SRC
sessions across rebuilds and contain FIFO min/max/weighted mean, ratio
adjustment count and min/max, underruns/overruns, resynchronizations, dropped
frames, observed estimated-latency min/max, the configured latency ceiling,
maximum callback gaps and execution times, callback execution-deadline misses,
render/converter errors, effective output/rate changes, and pipeline rebuilds.
For intentional input/rate interruptions, earlier session errors remain in the
report as expected-interruption diagnostics while the recovered final session
must be clean. Native common-rate sessions have no SRC FIFO and therefore do
not contribute FIFO or ratio fields.

## Known limits

- The displayed latency is an internal estimate, not measured physical
  end-to-end latency.
- The 5/10 ms objectives depend on the frame sizes exposed and accepted by both
  devices and on real-time scheduling stability.
- 256/512-frame automatic tiers prioritize recovery over the preferred latency
  target. Explicit 1024/2048-frame settings are supported by the UI but are not
  part of the automatic escalation ladder.
- Bluetooth codec and radio latency are outside ScreamBar and can dominate total
  monitoring delay even when the app reports a few milliseconds.
- Dynamic clock correction is intentionally bounded to +/-0.15%; a pair with
  more extreme clock error will exhaust the stability policy rather than apply
  unbounded pitch/rate correction.
