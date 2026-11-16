import AudioToolbox
import CoreAudio
import Foundation
import os

/// Gains shared between the main thread (writer) and the audio IO thread (reader).
/// Single Float stores and loads are atomic on Apple silicon, so no lock is used on the IO path.
final class GainBox {
    let count: Int
    let target: UnsafeMutablePointer<Float>
    let current: UnsafeMutablePointer<Float>
    /// Buffers per tap in the aggregate's input list (1 = interleaved). Read on the IO thread.
    let tapBufferCounts: UnsafeMutablePointer<Int>
    let totalTapBuffers: Int
    /// Peak meters: [0] = loudest tap input sample, [1] = loudest output sample.
    /// Written by the IO thread, read and reset by the main thread (a lost update is harmless).
    let peaks: UnsafeMutablePointer<Float>

    init(_ initial: [Float], tapBufferCounts counts: [Int]) {
        count = min(initial.count, counts.count)
        target = .allocate(capacity: count)
        current = .allocate(capacity: count)
        tapBufferCounts = .allocate(capacity: count)
        for i in 0..<count {
            target[i] = initial[i]
            current[i] = initial[i]
            tapBufferCounts[i] = counts[i]
        }
        totalTapBuffers = counts.reduce(0, +)
        peaks = .allocate(capacity: 2)
        peaks[0] = 0
        peaks[1] = 0
    }

    func set(_ gains: [Float]) {
        for i in 0..<min(count, gains.count) { target[i] = gains[i] }
    }

    deinit {
        target.deallocate()
        current.deallocate()
        tapBufferCounts.deallocate()
        peaks.deallocate()
    }
}

/// Captures system audio with Core Audio process taps, applies gain, and plays it
/// to one physical output device through a private aggregate device.
///
/// Tap 0 is the "everything else" global tap. Taps 1...n are per-app taps.
/// All taps mute the original audio, so the only thing the device hears is our mix.
/// Taps are private and owned by this process: if Knob quits or crashes, they vanish
/// and system audio goes straight to the device again.
final class TapEngine {
    private(set) var isRunning = false
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = HAL.unknown
    private var procID: AudioDeviceIOProcID?
    private var gains: GainBox?
    private let queue = DispatchQueue(label: Knob.id + ".audio-io", qos: .userInteractive)
    private let log = Logger(subsystem: Knob.id, category: "engine")

    /// - Parameters:
    ///   - outputDeviceUID: physical device to play to.
    ///   - excludedProcesses: process objects the global tap must ignore (always include Knob itself).
    ///   - appTaps: one array of process objects per adjusted app.
    ///   - initialGains: one gain per tap: [global, app1, app2, ...].
    func start(outputDeviceUID: String,
               excludedProcesses: [AudioObjectID],
               appTaps: [[AudioObjectID]],
               initialGains: [Float]) throws {
        stop()
        do {
            var tapUIDs: [String] = []
            var tapBufferCounts: [Int] = []

            let globalExclusions = excludedProcesses + appTaps.flatMap { $0 }
            let global = CATapDescription(stereoGlobalTapButExcludeProcesses: globalExclusions)
            try addTap(global, name: "Knob global", uids: &tapUIDs, bufferCounts: &tapBufferCounts)

            for (index, objects) in appTaps.enumerated() {
                let app = CATapDescription(stereoMixdownOfProcesses: objects)
                try addTap(app, name: "Knob app \(index + 1)", uids: &tapUIDs, bufferCounts: &tapBufferCounts)
            }

            let aggregateUID = "Knob-" + UUID().uuidString
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Knob",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
                kAudioAggregateDeviceTapListKey: tapUIDs.map {
                    [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] as [String: Any]
                },
            ]
            var aggregate = HAL.unknown
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Create aggregate device")
            aggregateID = aggregate

            let box = GainBox(initialGains, tapBufferCounts: tapBufferCounts)
            gains = box
            let counts = tapBufferCounts
            let totalTapBuffers = box.totalTapBuffers

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, output, _ in
                TapEngine.render(input: input, output: output, gains: box)
            }, "Create IO proc")
            procID = proc

            // render() writes and reads Float32 only. Check the formats the IO proc will see.
            let inFormats = HAL.streamFormats(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outFormats = HAL.streamFormats(aggregate, scope: kAudioObjectPropertyScopeOutput)
            log.info("Aggregate formats: in \(inFormats.map(HAL.describe).description, privacy: .public), out \(outFormats.map(HAL.describe).description, privacy: .public)")
            guard !outFormats.isEmpty, (inFormats + outFormats).allSatisfy(HAL.isFloat32) else {
                throw HALError(what: "Aggregate stream format is not Float32", status: -1)
            }

            // render() assumes the tap buffers come LAST in the input buffer list, after the
            // physical device's own input buffers. Refuse to start if the counts don't add up.
            let physical = HAL.device(forUID: outputDeviceUID)
            let deviceInputBuffers = HAL.bufferChannels(physical, scope: kAudioObjectPropertyScopeInput).count
            let aggregateInputBuffers = HAL.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeInput).count
            log.info("Input buffers: device \(deviceInputBuffers) + taps \(totalTapBuffers), aggregate has \(aggregateInputBuffers)")
            guard physical != HAL.unknown, aggregateInputBuffers == deviceInputBuffers + totalTapBuffers else {
                throw HALError(what: "Unexpected aggregate input layout (\(aggregateInputBuffers) buffers, expected \(deviceInputBuffers) + \(totalTapBuffers))", status: -1)
            }

            try check(AudioDeviceStart(aggregate, proc), "Start aggregate device")
            isRunning = true

            log.info("Engine started: \(tapUIDs.count) taps, tap buffers \(counts.description, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logLayout(expectedTapBuffers: totalTapBuffers) }
        } catch {
            stop()
            throw error
        }
    }

    func setGains(_ values: [Float]) {
        gains?.set(values)
    }

    /// Peak input and output levels since the last call, then resets them. Main thread only.
    func takePeaks() -> (input: Float, output: Float)? {
        guard let gains else { return nil }
        let result = (gains.peaks[0], gains.peaks[1])
        gains.peaks[0] = 0
        gains.peaks[1] = 0
        return result
    }

    func stop() {
        if aggregateID != HAL.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs = []
        aggregateID = HAL.unknown
        procID = nil
        gains = nil
        isRunning = false
    }

    deinit { stop() }

    // MARK: - Setup helpers

    private func addTap(_ description: CATapDescription, name: String,
                        uids: inout [String], bufferCounts: inout [Int]) throws {
        description.uuid = UUID()
        description.name = name
        description.muteBehavior = .muted
        description.isPrivate = true
        var tapID = HAL.unknown
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap (\(name))")
        tapIDs.append(tapID)
        uids.append(description.uuid.uuidString)

        var addr = HAL.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "Read tap format (\(name))")
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        log.info("Tap \(name, privacy: .public): \(HAL.describe(format), privacy: .public)")
        // render() reads Float32 only; anything else would play as noise, so refuse to start.
        guard HAL.isFloat32(format) else {
            throw HALError(what: "Tap \(name) format is \(HAL.describe(format)), expected Float32", status: -1)
        }
        bufferCounts.append(nonInterleaved ? Int(format.mChannelsPerFrame) : 1)
    }

    /// Logs the aggregate's input layout. The render code assumes tap buffers come LAST in the
    /// input buffer list (after any input streams the physical device itself has).
    private func logLayout(expectedTapBuffers: Int) {
        guard aggregateID != HAL.unknown else { return }
        let inputs = HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let outputs = HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        log.info("Aggregate layout: input buffers \(inputs.description, privacy: .public), output buffers \(outputs.description, privacy: .public), expected tap buffers \(expectedTapBuffers)")
    }

    // MARK: - Real-time render (no allocation, no locks, no logging)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gains: GainBox) {
        let tapBufferCounts = gains.tapBufferCounts
        let totalTapBuffers = gains.totalTapBuffers
        var inPeak = gains.peaks[0]
        var outPeak = gains.peaks[1]
        defer {
            gains.peaks[0] = inPeak
            gains.peaks[1] = outPeak
        }
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var outChannels = 0
        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            outChannels += Int(buffer.mNumberChannels)
        }
        guard outList.count > 0, outChannels > 0 else { return }
        let firstOut = outList[0]
        guard firstOut.mNumberChannels > 0 else { return }
        let outFrames = Int(firstOut.mDataByteSize) / (Int(firstOut.mNumberChannels) * MemoryLayout<Float>.size)

        var bufferIndex = inList.count - totalTapBuffers
        guard bufferIndex >= 0 else { return }

        for tap in 0..<gains.count {
            let startGain = gains.current[tap]
            let endGain = gains.target[tap]
            gains.current[tap] = endGain

            let bufferCount = tapBufferCounts[tap]
            defer { bufferIndex += bufferCount }
            guard bufferIndex + bufferCount <= inList.count else { break }

            let left: UnsafeMutablePointer<Float>
            let right: UnsafeMutablePointer<Float>
            let stride: Int
            let inFrames: Int
            let rightOffset: Int

            if bufferCount == 1 {
                let buffer = inList[bufferIndex]
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                left = data
                right = data
                stride = channels
                rightOffset = channels > 1 ? 1 : 0
                inFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            } else {
                let a = inList[bufferIndex]
                let b = inList[bufferIndex + 1]
                guard let da = a.mData?.assumingMemoryBound(to: Float.self),
                      let db = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                left = da
                right = db
                stride = 1
                rightOffset = 0
                inFrames = Int(a.mDataByteSize) / MemoryLayout<Float>.size
            }

            let frames = min(inFrames, outFrames)
            guard frames > 0 else { continue }
            let step = (endGain - startGain) / Float(frames)

            for frame in 0..<frames {
                let g = startGain + step * Float(frame)
                let rawL = left[frame * stride]
                let rawR = right[frame * stride + rightOffset]
                inPeak = max(inPeak, abs(rawL), abs(rawR))
                let l = rawL * g
                let r = rawR * g
                addToOutput(left: l, right: r, frame: frame, outList: outList, outChannels: outChannels)
            }
        }

        // Soft limit so boosts can't pass full scale: samples up to `knee` are untouched,
        // anything above is rounded off smoothly towards 1.0 instead of hard clipping.
        for buffer in outList {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<samples {
                let v = softLimit(data[i])
                data[i] = v
                outPeak = max(outPeak, abs(v))
            }
        }
    }

    private static let knee: Float = 0.9

    @inline(__always)
    private static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > knee else { return x }
        let range = 1 - knee
        let y = knee + range * tanhf((a - knee) / range)
        return x < 0 ? -y : y
    }

    @inline(__always)
    private static func addToOutput(left: Float, right: Float, frame: Int,
                                    outList: UnsafeMutableAudioBufferListPointer, outChannels: Int) {
        if outChannels == 1 {
            let buffer = outList[0]
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) { data[frame] += (left + right) * 0.5 }
            return
        }
        // Stereo into the first two channels of the device; any extra channels stay silent.
        var base = 0
        for buffer in outList {
            let channels = Int(buffer.mNumberChannels)
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                for c in 0..<channels {
                    let global = base + c
                    if global == 0 { data[frame * channels + c] += left }
                    else if global == 1 { data[frame * channels + c] += right }
                }
            }
            base += channels
            if base >= 2 { break }
        }
    }
}
