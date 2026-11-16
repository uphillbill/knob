## What does this change?

## Why?

Fixes #

## How was it tested?

- macOS version:
- Output devices tested (HDMI, DisplayPort, USB optical, built-in, Bluetooth…):
- Apps playing during the test:

## Checklist

- [ ] `swift build` passes with no new warnings
- [ ] Real-time code (`TapEngine.render` and callees) has no allocation, locks, logging or Objective-C messaging
- [ ] Errors stop the engine so audio goes straight to the device
- [ ] No new dependencies, network access or stored data
- [ ] `CLAUDE.md` checklist updated if hardware behavior was verified
