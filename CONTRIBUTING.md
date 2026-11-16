# Contributing to Knob

Thanks for helping. Bug reports, testing on hardware you have, and pull requests are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Knob has **no third-party dependencies**, makes **no network connections**, and stores only a few UserDefaults keys. Changes that alter any of that need discussion first.

## Build

```bash
xcode-select --install     # once, if needed
swift build                # compile only
./scripts/make-app.sh      # build, sign, install to ~/Applications and launch
```

To keep permissions across rebuilds, sign with a stable identity: copy `.signing.env.example` to `.signing.env` and set `SIGN_ID`. Logs:

```bash
/usr/bin/log stream --predicate 'subsystem == "io.github.uphillbill.knob"' --level debug
```

If audio goes silent while testing, turn **Knob on** off in the menu or run `killall Knob`.

## Rules for the audio code

- `TapEngine.render` and everything it calls run on the real-time audio thread: no allocation, locks, logging, Swift collections or strings, or Objective-C messaging.
- Fail safe: on any error, stop the engine so audio goes straight to the device.

`CLAUDE.md` has the architecture, these rules in more detail, and a hardware verification checklist. If you test on hardware, please note what you tested (device type, macOS version) in your pull request.

## Pull requests

- Keep each PR focused on one change.
- Make sure `swift build` passes with no new warnings.
- Describe how you tested it, including the output devices you used.

By contributing you agree that your contributions are licensed under the MIT License.
