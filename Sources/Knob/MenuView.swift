import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var audio: AudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Output")
            ForEach(audio.devices) { device in
                Button {
                    audio.select(device: device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .opacity(device.id == audio.currentDevice?.id ? 1 : 0)
                            .frame(width: 14)
                        Text(device.name).lineLimit(1)
                        Spacer()
                        if !device.hasHardwareVolume {
                            Text("Knob volume")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    audio.toggleMute()
                } label: {
                    Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(!audio.softwareMode)
                Slider(value: Binding(get: { Double(audio.masterVolume) },
                                      set: { audio.setMaster(Float($0)) }),
                       in: 0...1)
                Text("\(Int((audio.masterVolume * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }

            if !audio.apps.isEmpty {
                Divider()
                section("Apps")
                ForEach(audio.apps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon)
                        Text(app.name)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(app.isPlaying ? .primary : .secondary)
                        Slider(value: Binding(get: { Double(app.volume) },
                                              set: { audio.setAppVolume(app.key, Float($0)) }),
                               in: 0...2)
                        Text("\(Int((app.volume * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                        Button {
                            audio.toggleAppMute(app.key)
                        } label: {
                            Image(systemName: app.muted ? "speaker.slash" : "speaker.wave.1")
                                .frame(width: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    .contextMenu {
                        Button("Reset to 100%") { audio.resetApp(app.key) }
                    }
                }
            }

            Divider()

            Toggle("Knob on", isOn: Binding(get: { audio.isOn }, set: { audio.setOn($0) }))
            Toggle("Open at login", isOn: Binding(get: { audio.launchAtLogin }, set: { audio.setLaunchAtLogin($0) }))

            if !audio.accessibilityGranted {
                Button("Allow volume keys…") { audio.requestAccessibility() }
                Text("Grant Knob Accessibility access so the keyboard volume keys work on devices without volume.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(audio.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit Knob") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
