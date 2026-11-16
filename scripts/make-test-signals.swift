#!/usr/bin/env swift
// Writes EQ test signals as 48 kHz stereo WAV files:
//   pink-noise.wav  30 s of pink noise (about -20 dBFS RMS), for judging tone and listening for clicks
//   sweep.wav       20 s logarithmic sine sweep from 20 Hz to 20 kHz at -12 dBFS, for hearing each band
//
//   swift scripts/make-test-signals.swift [output folder]    # default: build/test-signals
//   afplay build/test-signals/pink-noise.wav
import AVFoundation

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/test-signals")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let rate = 48000.0

func write(_ name: String, seconds: Double, sample: (Int) -> Float) throws {
    let frames = Int(seconds * rate)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let fade = Int(0.05 * rate)   // 50 ms fades, so the files start and stop without a click
    for i in 0..<frames {
        let envelope = Float(min(1, Double(min(i, frames - 1 - i)) / Double(fade)))
        let v = sample(i) * envelope
        buffer.floatChannelData![0][i] = v
        buffer.floatChannelData![1][i] = v
    }
    let url = folder.appendingPathComponent(name)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
    print("Wrote \(url.path)")
}

// Pink noise: Paul Kellet's filter over white noise.
var b = [Float](repeating: 0, count: 7)
var generator = SystemRandomNumberGenerator()
try write("pink-noise.wav", seconds: 30) { _ in
    let white = Float.random(in: -1...1, using: &generator)
    b[0] = 0.99886 * b[0] + white * 0.0555179
    b[1] = 0.99332 * b[1] + white * 0.0750759
    b[2] = 0.96900 * b[2] + white * 0.1538520
    b[3] = 0.86650 * b[3] + white * 0.3104856
    b[4] = 0.55000 * b[4] + white * 0.5329522
    b[5] = -0.7616 * b[5] - white * 0.0168980
    let pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
    b[6] = white * 0.115926
    return pink * 0.05
}

// Exponential sweep: instantaneous frequency f0 * (f1/f0)^(t/T).
let (f0, f1, duration) = (20.0, 20000.0, 20.0)
let k = log(f1 / f0)
try write("sweep.wav", seconds: duration) { i in
    let t = Double(i) / rate
    let phase = 2 * Double.pi * f0 * duration / k * (exp(t / duration * k) - 1)
    return Float(0.25 * sin(phase))
}
