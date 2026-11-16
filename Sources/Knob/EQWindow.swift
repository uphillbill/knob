import AppKit
import KnobDSP
import SwiftUI

/// View state for the EQ window. (Kept in an object rather than @State: with the Command Line
/// Tools alone, the SwiftUI macro plugin that @State needs isn't available.)
final class EQWindowModel: ObservableObject {
    @Published var savingPreset = false
    @Published var newPresetName = ""
}

/// The "Knob EQ" window: 10 bands plus preamp for the current output device or one app.
struct EQWindow: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var model: EQWindowModel

    private var target: AudioController.EQTarget {
        if case .app(let key) = audio.eqTarget, !audio.apps.contains(where: { $0.key == key }) { return .device }
        return audio.eqTarget
    }
    private var settings: EQSettings { audio.eqSettings(for: target) }
    private var app: AudioController.AppEntry? {
        if case .app(let key) = target { return audio.apps.first { $0.key == key } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            EQResponseView(settings: settings, dimmed: app.map { !$0.eqOn } ?? false)
                .frame(height: 96)
            sliders
            footer
        }
        .padding(18)
        .frame(width: 560)
        .alert("Save preset", isPresented: $model.savingPreset) {
            TextField("Name", text: $model.newPresetName)
            Button("Save") { audio.saveUserPreset(named: model.newPresetName, settings) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved presets appear in every EQ preset menu.")
        }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 12) {
            Picker("EQ for", selection: Binding(get: { target }, set: { audio.eqTarget = $0 })) {
                Text("\(audio.currentDevice?.name ?? "Output") (all audio)").tag(AudioController.EQTarget.device)
                if !audio.apps.isEmpty {
                    Divider()
                    ForEach(audio.apps) { app in
                        Text(app.name).tag(AudioController.EQTarget.app(app.key))
                    }
                }
            }
            .frame(maxWidth: 320)
            Spacer()
            if let app {
                Toggle("EQ on", isOn: Binding(get: { app.eqOn }, set: { audio.setAppEQOn(app.key, $0) }))
                    .toggleStyle(.switch)
                    .help("Gives \(app.name) its own EQ, applied before the device EQ")
            }
        }
    }

    private var sliders: some View {
        HStack(alignment: .top, spacing: 0) {
            EQBandSlider(label: "Preamp", value: settings.preamp, range: EQ.preampRange) { value in
                var s = settings; s.preamp = value; audio.setEQ(s, for: target)
            }
            Divider().padding(.horizontal, 8).frame(height: 200)
            ForEach(0..<EQ.bandCount, id: \.self) { band in
                EQBandSlider(label: EQ.label(forBand: band), value: settings.bands[band], range: EQ.bandRange) { value in
                    var s = settings; s.bands[band] = value; audio.setEQ(s, for: target)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        let current = audio.presetName(for: settings)
        let peak = EQ.peakDB(settings)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Preset", selection: Binding(get: { current ?? "" }, set: { name in
                    if let preset = audio.allPresets.first(where: { $0.name == name }) {
                        audio.setEQ(preset.settings, for: target)
                    }
                })) {
                    ForEach(Array(audio.presetGroups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        ForEach(group) { Text($0.name).tag($0.name) }
                    }
                    if current == nil { Divider(); Text("Custom").tag("") }
                }
                .frame(width: 220)
                Button("Reset") { audio.setEQ(.flat, for: target) }
                    .disabled(settings.isFlat)
                Button("Save as Preset…") {
                    model.newPresetName = ""
                    model.savingPreset = true
                }
                .disabled(current != nil)
                if let name = current, audio.userPresets.contains(where: { $0.name == name }) {
                    Button("Delete Preset") { audio.deleteUserPreset(named: name) }
                }
                Spacer()
            }
            if peak > 0.5 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Boosts up to \(String(format: "%+.1f", peak)) dB. Loud audio may reach the limiter.")
                    Button("Lower preamp") {
                        var s = settings
                        s.preamp = max(EQ.preampRange.lowerBound, (s.preamp - Float(peak) * 2).rounded() / 2)
                        audio.setEQ(EQSettings(bands: s.bands, preamp: s.preamp), for: target)
                    }
                    .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Double-click a slider to reset it to 0 dB. Hold Option for 0.1 dB steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A vertical dB slider: value on top, track, frequency label below.
private struct EQBandSlider: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    private let trackHeight: CGFloat = 160

    var body: some View {
        VStack(spacing: 6) {
            Text(abs(value) < 0.05 ? "0" : String(format: "%+.1f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(height: 14)
            track
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 42)
    }

    private var track: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = range.upperBound - range.lowerBound
            let y: (Float) -> CGFloat = { v in height * CGFloat((range.upperBound - v) / span) }
            ZStack(alignment: .top) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(width: 4)
                // Fill from 0 dB to the value.
                let zero = y(0), at = y(value)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(at - zero))
                    .offset(y: min(at, zero))
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 12, height: 1).offset(y: zero)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    .frame(width: 16, height: 16)
                    .offset(y: at - 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    set(range.upperBound - Float(drag.location.y / height) * span,
                        step: NSEvent.modifierFlags.contains(.option) ? 0.1 : 0.5)
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
        .frame(height: trackHeight)
    }

    private func set(_ raw: Float, step: Float) {
        let stepped = (raw / step).rounded() * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        if clamped != value { onChange(clamped) }
    }
}

/// Frequency response from 20 Hz to 20 kHz, preamp included, on a ±15 dB grid.
private struct EQResponseView: View {
    let settings: EQSettings
    let dimmed: Bool

    var body: some View {
        Canvas { context, size in
            let range = 15.0
            let y: (Double) -> CGFloat = { db in size.height * CGFloat((range - min(max(db, -range), range)) / (2 * range)) }
            let x: (Double) -> CGFloat = { f in size.width * CGFloat(log10(f / 20) / 3) }

            var grid = Path()
            for db in [-12.0, -6, 6, 12] {
                grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: size.width, y: y(db)))
            }
            for f in [100.0, 1000, 10000] {
                grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(zero, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)

            var curve = Path()
            let points = 200
            for i in 0...points {
                let f = 20 * pow(1000, Double(i) / Double(points))
                let p = CGPoint(x: x(f), y: y(EQ.responseDB(settings, at: f)))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(dimmed ? .secondary : .accentColor), lineWidth: 2)

            for (f, text) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
                context.draw(Text(text).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(f) + 3, y: size.height - 6), anchor: .leading)
            }
            context.draw(Text("+12").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 3, y: y(12)), anchor: .leading)
            context.draw(Text("−12").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 3, y: y(-12)), anchor: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
