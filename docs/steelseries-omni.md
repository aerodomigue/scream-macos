# SteelSeries Omni headset controls

[Back to the README](../README.md#steelseries-omni)

ScreamBar monitors and controls the Arctis Nova Pro Omni base over USB HID.
The base handles audio; this mode stops ScreamBar's software audio routing.
PC monitoring, Wake-on-LAN, and paired shutdown remain available.

## Setup

Select **SteelSeries Omni** and connect the Mac to **USB1** on the **SteelSeries Arctis Nova Pro Omni** base. Status shows:

- whether the headset is connected to the base;
- the base's current volume, above the battery rows;
- the headset battery percentage;
- the spare battery percentage reported by the base's charging slot.

## Menu bar and battery status

A separate **headphones + percentage** item appears in the menu bar only in this mode, white on the active display and light gray on an inactive display. Move it independently with **Command-drag**. Clicking it opens the battery popup; clicking outside closes it. The main application icon remains available for settings and PC status.

Status is read every five seconds in the background, without SteelSeries GG and without changing the base's audio settings. If the headset disconnects, its old battery percentage is hidden. Unavailable values appear as `—`, and a missing or unresponsive base is reported explicitly. Monitoring pauses during sleep and stops when another mode is selected.

## Volume keys and permissions

**Volume + / − and Mute keys** control the base's hardware volume while Omni mode is active, the headset is connected, and Omni is the Mac's default sound output. Click **Allow volume keys…** in Status or the headset popup and enable ScreamBar in **System Settings → Privacy & Security → Accessibility**. Each press moves one hardware step (about 1.8 percentage points); holding a key repeats. Rapid presses are combined without dropping their effect, including changes of direction at the volume limits. The displayed percentage follows key presses immediately and is checked against the base after the burst. Accepted keys also show a compact macOS-style volume indicator near the upper-right corner of the screen containing the pointer; it disappears 1.5 seconds after the last press without taking focus or adding USB polling.

### USB traffic and responsiveness

ScreamBar reads the current volume at the start of each key sequence, then sends changes using the last successfully written value. It verifies the result after 150 ms without a new press; this quiet interval delays only verification, never writes. Dial changes are picked up at the start of the next sequence. Holding a key at 0% or 100% sends no redundant volume commands. Both views share one volume refresh about once a second while visible; closing them stops volume polling. Battery status is still checked every five seconds in Omni mode. Unchanged values do not trigger interface updates. USB operations run in the background, with at least 50 ms between commands; pending adjustments are cancelled when the mode or output changes. The macOS Control Center volume slider is not handled by this feature. It changes no audio routing and adds no audio processing latency.

## Mute and recovery

**Mute** is intercepted before macOS handles it, avoiding the native mute/unmute loop. It sets the base volume to 0%; pressing Mute again restores the previously read volume. Holding Mute toggles only once. Volume + / − leaves mute and adjusts from zero. The popup and volume indicator show the muted state. A physical dial change to a nonzero value clears it. An unknown initial 0% never restores an invented volume, and leaving Omni mode, changing output, or disconnecting clears the saved restore value. Temporary USB failures preserve a known restore value and keep eligible keys intercepted, with a one-second pause before another keyboard operation. Queued actions and error logs are bounded.

## Supported hardware and limits

The USB status request and hardware volume read/write have been validated on USB1. USB2 is detected, but did not return status during testing; the application asks you to use USB1. This integration is specific to the **Arctis Nova Pro Omni**, not a claim of support for other SteelSeries headsets. It does not switch macOS audio devices or control ANC or ChatMix.
