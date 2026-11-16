// DSP checks for Knob's EQ. Run with `swift run -c release EQCheck`; exits 1 on any failure.
import Foundation
import KnobDSP

var failures = 0
func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition { return }
    failures += 1
    print("FAIL  \(message())")
}
func section(_ title: String) { print("- \(title)") }

let block = 512
let builtIn = EQPreset.builtIn.map(\.settings)

/// Runs a 2-channel bank over `frames` samples produced by `input`, one 512-frame buffer at a
/// time, calling `between` before each buffer (to publish changes). Returns channel 0's output.
func run(_ bank: EQFilterBank, frames: Int, input: (Int) -> Float,
         between: (Int) -> Void = { _ in }) -> [Float] {
    var out = [Float](repeating: 0, count: frames)
    var buffer = [Float](repeating: 0, count: 2 * block)
    var done = 0
    var index = 0
    while done < frames {
        let n = min(block, frames - done)
        for i in 0..<n {
            buffer[i] = input(done + i)
            buffer[block + i] = buffer[i]
        }
        between(index)
        buffer.withUnsafeMutableBufferPointer { p in
            bank.state.beginBuffer()
            bank.state.process(p.baseAddress!, channelStride: block, channels: 2, frames: n)
        }
        for i in 0..<n { out[done + i] = buffer[i] }
        done += n
        index += 1
    }
    return out
}

/// Measured gain in dB of a sine at `frequency`, after the filters settle.
func measuredDB(_ settings: EQSettings, at frequency: Double, sampleRate: Double) -> Double {
    let bank = EQFilterBank(channels: 2, sampleRate: sampleRate, initial: settings)
    let settle = Int(sampleRate)                                   // 1 s
    let window = Int((max(20, frequency / 10) * sampleRate / frequency).rounded())  // whole cycles
    let w = 2 * Double.pi * frequency / sampleRate
    let out = run(bank, frames: settle + window) { Float(0.1 * sin(w * Double($0))) }
    var inSum = 0.0, outSum = 0.0
    for i in settle..<(settle + window) {
        let x = 0.1 * sin(w * Double(i))
        inSum += x * x
        outSum += Double(out[i]) * Double(out[i])
    }
    return 10 * log10(outSum / inSum)
}

// MARK: -

section("Flat is bit-identical (and skipped)")
do {
    var rng = SystemRandomNumberGenerator()
    let noise = (0..<48000).map { _ in Float.random(in: -1...1, using: &rng) }
    for settings in [EQSettings.flat, EQSettings(bands: [0.01, -0.02, 0, 0, 0, 0, 0, 0, 0.03, 0], preamp: 0.01)] {
        expect(settings.isFlat, "near-zero settings count as flat")
        let out = run(EQFilterBank(channels: 2, sampleRate: 48000, initial: settings), frames: noise.count) { noise[$0] }
        expect(out == noise, "flat output equals input bit for bit")
    }
}

section("Single bands: analytic response and measured sine gain")
for rate in [44100.0, 48000, 96000] {
    for band in 0..<EQ.bandCount {
        for gain: Float in [12, -12, 4.5] {
            var bands = [Float](repeating: 0, count: EQ.bandCount)
            bands[band] = gain
            let settings = EQSettings(bands: bands)
            let f = EQ.frequencies[band]
            let analytic = EQ.responseDB(settings, at: f, sampleRate: rate)
            let expected = (band == 0 || band == EQ.bandCount - 1) ? Double(gain) / 2 : Double(gain)
            expect(abs(analytic - expected) < 0.05,
                   "\(EQ.label(forBand: band)) Hz \(gain) dB @ \(Int(rate)): analytic \(analytic), expected \(expected)")
            let measured = measuredDB(settings, at: f, sampleRate: rate)
            expect(abs(measured - analytic) < 0.1,
                   "\(EQ.label(forBand: band)) Hz \(gain) dB @ \(Int(rate)): measured \(measured), analytic \(analytic)")
        }
    }
}

section("Presets and preamp: measured matches analytic")
for settings in builtIn + [EQSettings(bands: [], preamp: -6)] where !settings.isFlat {
    for f in [40.0, 100, 440, 1000, 3000, 10000] {
        let analytic = EQ.responseDB(settings, at: f, sampleRate: 48000)
        let measured = measuredDB(settings, at: f, sampleRate: 48000)
        expect(abs(measured - analytic) < 0.1, "\(settings.bands) pre \(settings.preamp) @ \(f) Hz: measured \(measured), analytic \(analytic)")
    }
}
expect(abs(EQ.responseDB(EQSettings(bands: [], preamp: -6), at: 1000) + 6) < 0.001, "preamp -6 dB")

section("Stability with Float32 coefficients")
do {
    var extremes = builtIn
    extremes.append(EQSettings(bands: [Float](repeating: 12, count: 10)))
    extremes.append(EQSettings(bands: [Float](repeating: -12, count: 10)))
    extremes.append(EQSettings(bands: (0..<10).map { $0 % 2 == 0 ? 12 : -12 }))
    for rate in [22050.0, 32000, 44100, 48000, 88200, 96000, 176400, 192000] {
        for settings in extremes {
            for band in 0..<EQ.bandCount {
                let c = Biquad.band(band, gainDB: Double(settings.bands[band]), sampleRate: rate)
                let f = Biquad(b0: Double(Float(c.b0)), b1: Double(Float(c.b1)), b2: Double(Float(c.b2)),
                               a1: Double(Float(c.a1)), a2: Double(Float(c.a2)))
                expect(c.isStable && f.isStable, "band \(band) of \(settings.bands) stable @ \(Int(rate))")
            }
        }
    }
}

section("Stress: new random settings every buffer, 20 s of noise")
do {
    let bank = EQFilterBank(channels: 2, sampleRate: 48000, initial: .flat)
    var rng = SystemRandomNumberGenerator()
    let out = run(bank, frames: 48000 * 20, input: { _ in Float.random(in: -0.5...0.5) }) { index in
        if index % 7 == 3 { bank.publish(.flat); return }
        bank.publish(EQSettings(bands: (0..<10).map { _ in Float.random(in: -12...12, using: &rng) },
                                preamp: Float.random(in: -12...6, using: &rng)))
    }
    expect(out.allSatisfy { $0.isFinite }, "output stays finite")
    let peak = out.map(abs).max() ?? 0
    expect(peak < 40, "output stays bounded (peak \(peak))")
}

section("Coefficient ramp: no step when a band jumps from 0 to +12 dB")
do {
    let rate = 48000.0, f = 1000.0, amplitude = 0.2
    let w = 2 * Double.pi * f / rate
    let bank = EQFilterBank(channels: 2, sampleRate: rate, initial: .flat)
    var bands = [Float](repeating: 0, count: 10)
    bands[5] = 12
    let boosted = EQSettings(bands: bands)
    let out = run(bank, frames: Int(rate)) { Float(amplitude * sin(w * Double($0))) } between: { index in
        if index == 20 { bank.publish(boosted) }
        if index == 60 { bank.publish(.flat) }
    }
    // A sine's largest sample-to-sample step is about 2π·f/fs × its amplitude. The boosted sine
    // is 4× louder; allow 20% on top. A hard switch would step by up to the full amplitude.
    var maxStep: Float = 0
    for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
    let bound = Float(w * amplitude * pow(10, 12.0 / 20) * 1.2)
    expect(maxStep < bound, "largest step \(maxStep) < \(bound)")
    // After the change settles, the gain is the new setting.
    let measured = measuredDB(boosted, at: f, sampleRate: rate)
    expect(abs(measured - 12) < 0.1, "picked up the published setting (\(measured) dB)")
}

section("Hand-off: the latest published setting wins")
do {
    let bank = EQFilterBank(channels: 2, sampleRate: 48000, initial: .flat)
    for g: Float in [3, -3, 6] {
        var bands = [Float](repeating: 0, count: 10); bands[5] = g
        bank.publish(EQSettings(bands: bands))
    }
    let w = 2 * Double.pi * 1000 / 48000
    let out = run(bank, frames: 48000) { Float(0.1 * sin(w * Double($0))) }
    let tail = out.suffix(4800).map { Double($0) * Double($0) }.reduce(0, +) / 4800
    let db = 10 * log10(tail / 0.005)
    expect(abs(db - 6) < 0.1, "gain after three publishes is +6 dB (\(db))")
}

section("Presets fit the slider ranges")
for preset in EQPreset.builtIn {
    expect(preset.settings.bands.count == EQ.bandCount, "\(preset.name) has 10 bands")
    expect(preset.settings.bands.allSatisfy { EQ.bandRange.contains($0) }, "\(preset.name) bands in range")
    let peak = EQ.peakDB(preset.settings)
    expect(peak < 0.05, "\(preset.name) peaks at or below 0 dB (\(peak))")
    print("  \(preset.name.padding(toLength: 15, withPad: " ", startingAt: 0)) preamp \(String(format: "%+5.1f", preset.settings.preamp)) dB, peak \(String(format: "%+.1f", peak)) dB")
}

if failures == 0 {
    print("All EQ checks passed.")
} else {
    print("\(failures) EQ check(s) failed.")
    exit(1)
}
