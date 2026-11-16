# Knob: guide for AI coding agents

Knob is a macOS menu bar app that:

1. Gives volume control to output devices macOS can't adjust (optical/S/PDIF adapters, HDMI, DisplayPort), including the keyboard volume keys and an on-screen indicator.
2. Sets per-app volume (0 to 200%) and per-app mute.
3. Switches the output device from the menu bar and remembers a volume per device.

Target: macOS 14.2 or later, Apple silicon. Swift 5 language mode, Swift Package Manager, **no third-party dependencies**. Bundle ID and log subsystem: `io.github.uphillbill.knob` (`Knob.id` in `KnobApp.swift`).

Read the ground rules before touching `TapEngine.swift`. Human contributors: see `CONTRIBUTING.md`.

## Ground rules

- **Real-time code** (`TapEngine.render` and everything it calls) must not allocate, take locks, log, use Swift arrays/dictionaries/strings, or send Objective-C messages. Share data with the IO thread through preallocated pointers (see `GainBox`).
- **Fail safe.** Anything that could silence the Mac must, on any error, stop the engine so audio goes straight to the device again. Prefer refusing to start over guessing (see the format and input-layout checks in `TapEngine.start`).
- **No network access, no new storage.** Knob stores only the UserDefaults keys listed under "Persistence". The README's privacy section promises this; update both if that ever changes.
- Keep it dependency-free.

## Build, run, logs

```bash
xcode-select --install          # if Xcode or the Command Line Tools aren't installed
swift build                     # compile only (what CI runs)
./scripts/make-app.sh           # builds, signs, installs to ~/Applications, launches
```

- Signing: `SIGN_ID` from the environment or from a gitignored `.signing.env` (see `.signing.env.example`); ad-hoc otherwise. Ad-hoc signing makes macOS re-ask for permissions after every rebuild, so use a stable identity (an Apple Development certificate or a self-signed code-signing certificate). After changing identity, remove Knob from Privacy & Security → Accessibility and add it again.
- Logs: `/usr/bin/log stream --predicate 'subsystem == "io.github.uphillbill.knob"' --level debug`. Use the full path: in zsh, `log` is a builtin.
  - info: engine start/stop, tap and aggregate formats, input buffer counts, menu actions, errors.
  - debug: device list (UIDs private), volume keys, master changes, and every 2 s `Levels: tap in peak …, out peak …` from a lock-free peak meter in `render`.
- Permissions: **System audio recording** (prompted when the engine first starts; needed for taps) and **Accessibility** (menu item "Allow volume keys…"; needed to swallow the volume keys).

## Architecture

| File | Role |
|---|---|
| `HAL.swift` | Core Audio HAL helpers: devices, default output, hardware volume, stream formats, audio process list. |
| `TapEngine.swift` | Process taps + private aggregate device + real-time mixing with per-tap gain, peak meter, soft limiter. |
| `AudioController.swift` | State and policy: when the engine runs, gains, volume curves, persistence, listeners. |
| `VolumeKeys.swift` | CGEventTap on NX_SYSDEFINED events for volume up/down/mute. |
| `VolumeHUD.swift` | Non-activating panel showing the volume level. |
| `MenuView.swift` | SwiftUI `MenuBarExtra` window: devices, master slider, per-app sliders. |
| `KnobApp.swift` | App entry, delegate, `Knob.id`. |

App icon: `Resources/AppIcon.icns`, built from `docs/images/icon.png` (1024 px, transparent) with `sips` + `iconutil`.

### Audio path

- The engine runs only when needed: the current device has no hardware volume, **or** a running app has a per-app setting other than 100%/unmuted. Otherwise it's stopped and audio is untouched.
- When running, every tap is tied to the **current output device's first output stream**, so apps playing to other devices are left alone:
  - Tap 0: `CATapDescription(excludingProcesses:deviceUID:stream: 0)` excluding Knob itself and every adjusted app.
  - Taps 1..n: `CATapDescription(processes:deviceUID:stream: 0)`, one per adjusted app (all of that app's helper processes).
  - Taps use the device stream's own format and channel count (no stereo mixdown).
  - Every tap is `.muted` and private, so the originals are silenced on that device and the taps die with the process.
  - One private aggregate device: main sub-device = the physical output, tap list = all taps with drift compensation.
- Render (`TapEngine.render`, state in `MixState`, all preallocated): for each block of up to 4096 frames, every tap is mixed channel-for-channel into a non-interleaved mix bus (tap channel c → device channel c; a mono tap feeds channels 0–1; a wider tap into a mono device averages its first two channels), each with its gain ramped linearly over the IO buffer. The mix is soft-limited into every output channel through a precomputed channel map (buffer, offset, stride).
- Start-up checks (engine refuses to start otherwise): Knob's own process object is known (else tap 0 would feed back), the device has an output stream, every tap and aggregate stream is Float32, taps run at the device's sample rate, and aggregate input buffers = device input buffers + tap buffers.
- Gains: global = master; app = master × app gain. Master is 1.0 when the device has its own volume (macOS handles it).
- Master curve (software mode): **50% = unity** (same level as Knob off). 0–50% is a cubic fade to unity; 50–100% boosts linearly in dB up to +12 dB. New devices and switching "Knob on" back on start at 50%, so the level doesn't jump. App curve: cubic for 0–100%, linear boost from 100–200%.
- Soft limiter: untouched below 0.9 full scale, tanh knee above, so boosts round off peaks rather than crackle.
- Rebuilds are debounced (0.4 s) and keyed by a signature of device + adjusted apps + their process objects. Gain-only changes never rebuild.

### Volume keys

- Swallowed only in software mode (device without hardware volume). Otherwise passed through to macOS.
- Step 1/16; Option+Shift for 1/64. Key-up events are swallowed too in software mode.

### Persistence

UserDefaults only (`~/Library/Preferences/io.github.uphillbill.knob.plist`):

| Key | Value |
|---|---|
| `isOn` | Knob on/off |
| `volumeCurveVersion` | settings format version (2 = unity at 50%) |
| `deviceVolume.<device UID>`, `deviceMuted.<device UID>` | master volume/mute for devices without hardware volume |
| `appVolume.<app bundle ID>`, `appMuted.<app bundle ID>` | per-app volume/mute, only for apps the user adjusted |

## Verification checklist

Test on real hardware and note results here (generic findings only; no personal setup details).

- [x] **Compiles.** Xcode 27.2 / Swift 6.4 / macOS 27.2 SDK. API note: the `CATapDescription` initializers take `[AudioObjectID]`, not `[NSNumber]`. `AudioHardwareService*` is marked deprecated but works: built-in speakers report hardware volume; USB optical adapters and DisplayPort monitors don't.
- [x] **No feedback loop.** `HAL.processObject(for: getpid())` returns a real object on first launch, before the engine starts. Level meter: output = input × gain, steady, no growth; clean by ear.
- [ ] **Input buffer layout.** Device without inputs (USB optical adapter): passes (device 0 + taps 1 = aggregate 1). **Untested** with a device that also has inputs (USB headset, audio interface); the start-up check refuses to start if the layout differs.
- [ ] **Format.** USB optical adapter: tap and aggregate in/out are 2ch 48 kHz Float32 interleaved. Built-in/display speakers still to check (needs an app with a per-app setting, since those devices have their own volume).
- [ ] **Sound quality.** Unity level matches Knob off exactly; +12 dB boost with the soft limiter is clean by ear. Still to do: 10+ minutes of music with no clicks or dropouts (clock drift).
- [ ] **Volume keys.** Up/down work in software mode, including the boost range. Still to check: mute, HUD, fine steps, the macOS "can't adjust" indicator no longer appearing, and normal behavior on a device with its own volume.
- [ ] **Per-app.** Lower Safari (audio comes from `com.apple.WebKit.*` processes, grouped as Safari), Chrome (helper processes), Music. Mute one app while another keeps playing.
- [ ] **Device switching.** Switching between an optical adapter and built-in speakers from Knob's menu and from System Settings, Knob on and off: passes. Once, an optical receiver stayed silent after switching back even with Knob off, until the device was reselected in System Settings (likely the receiver losing signal lock; not reproduced). Unplugging mid-playback: untested.
- [x] **Escape hatch.** Turning "Knob on" off stops the engine within ~50 ms and macOS plays straight to the device; turning it on restarts the engine.
- [ ] **Sleep/wake.** Audio and volume control come back after waking.
- [ ] **Permission denied.** If system audio recording is denied, taps may deliver silence while still muting the originals. Detect it (e.g. sustained all-zero input while `kAudioProcessPropertyIsRunningOutput` is true for some app) and stop the engine with a clear status message.
- [x] **Apps on other devices.** Taps are now limited to the current device's stream 0. Verified: with the engine running on a USB optical adapter, speech sent to the built-in speakers (`say -a "<device name>" …`) played on the built-in speakers, and the music on the adapter kept playing with volume and per-app control working. Devices with more than one output stream: only stream 0 is tapped (other streams play untouched); untested.
- [ ] **Copy-protected streams.** Streaming video in Safari, Apple Music. Confirm audio is captured, not silenced.
- [ ] **CPU.** Near zero when idle; low single digits while playing.

## Escape hatch

If audio goes silent: open the menu and turn "Knob on" off, or `killall Knob`. Taps belong to the process, so killing it restores normal audio immediately.

## Roadmap

- EQ.
- Per-app output routing.
- Loudness leveling across apps.
- Hotkeys and Shortcuts actions.
- Network volume for receivers and soundbars that expose one, so the volume keys move the speaker's own volume.
