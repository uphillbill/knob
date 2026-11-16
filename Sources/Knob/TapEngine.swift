import AudioToolbox
import CoreAudio
import Foundation
import KnobDSP
import os

/// Everything the IO thread needs, allocated before the engine starts and never resized.
/// The main thread writes gain targets; the IO thread reads them. Single Float stores and
/// loads are atomic on Apple silicon, so no lock is used on the IO path.
final class MixState {
    /// Frames processed per block. Longer IO buffers are processed in several blocks.
    static let blockSize = 4096

    let tapCount: Int
    let target: UnsafeMutablePointer<Float>
    let current: UnsafeMutablePointer<Float>
    /// Per tap: channel count, whether its data is interleaved (1) or one buffer per channel (0),
    /// and the index of its first buffer, counted from the first tap buffer in the input list.
    let tapChannels: UnsafeMutablePointer<Int>
    let tapInterleaved: UnsafeMutablePointer<Int>
    let tapFirstBuffer: UnsafeMutablePointer<Int>
    let totalTapBuffers: Int
    /// Output channel map: for each device channel, its buffer, offset within a frame, and stride.
    let outChannels: Int
    let outBuffer: UnsafeMutablePointer<Int>
    let outOffset: UnsafeMutablePointer<Int>
    let outStride: UnsafeMutablePointer<Int>
    /// Mix bus, one block of frames per output channel (non-interleaved).
    let mix: UnsafeMutablePointer<Float>
    /// Gains captured at the start of each render call.
    let startGain: UnsafeMutablePointer<Float>
    let endGain: UnsafeMutablePointer<Float>
    /// Peak meters: [0] = loudest tap input sample, [1] = loudest output sample.
    /// Written by the IO thread, read and reset by the main thread (a lost update is harmless).
    let peaks: UnsafeMutablePointer<Float>
    /// One tap's block, mapped to device channels, before its gain (app EQ runs here).
    let scratch: UnsafeMutablePointer<Float>
    /// EQ on the mix, and per tap (tapHasEQ[i] == 1 when tap i has an app EQ).
    /// The banks are main-thread objects; the IO thread only sees their `state` structs.
    let systemEQ: EQFilterBank
    let systemEQState: EQBankState
    let tapEQ: [EQFilterBank?]
    let tapEQState: UnsafeMutablePointer<EQBankState>
    let tapHasEQ: UnsafeMutablePointer<Int>

    struct Tap { let channels: Int; let interleaved: Bool }

    init(gains initial: [Float], taps: [Tap], outputBufferChannels: [Int],
         sampleRate: Double, systemEQ systemSettings: EQSettings, appEQ: [EQSettings?]) {
        tapCount = min(initial.count, taps.count)
        target = .allocate(capacity: tapCount)
        current = .allocate(capacity: tapCount)
        startGain = .allocate(capacity: tapCount)
        endGain = .allocate(capacity: tapCount)
        tapChannels = .allocate(capacity: tapCount)
        tapInterleaved = .allocate(capacity: tapCount)
        tapFirstBuffer = .allocate(capacity: tapCount)
        var first = 0
        for i in 0..<tapCount {
            target[i] = initial[i]
            current[i] = initial[i]
            startGain[i] = initial[i]
            endGain[i] = initial[i]
            tapChannels[i] = taps[i].channels
            tapInterleaved[i] = taps[i].interleaved ? 1 : 0
            tapFirstBuffer[i] = first
            first += taps[i].interleaved ? 1 : taps[i].channels
        }
        totalTapBuffers = first

        outChannels = outputBufferChannels.reduce(0, +)
        outBuffer = .allocate(capacity: max(outChannels, 1))
        outOffset = .allocate(capacity: max(outChannels, 1))
        outStride = .allocate(capacity: max(outChannels, 1))
        var channel = 0
        for (buffer, count) in outputBufferChannels.enumerated() {
            for c in 0..<count {
                outBuffer[channel] = buffer
                outOffset[channel] = c
                outStride[channel] = count
                channel += 1
            }
        }
        mix = .allocate(capacity: max(outChannels, 1) * Self.blockSize)
        scratch = .allocate(capacity: max(outChannels, 1) * Self.blockSize)
        peaks = .allocate(capacity: 2)
        peaks[0] = 0
        peaks[1] = 0

        let channels = max(outChannels, 1)
        systemEQ = EQFilterBank(channels: channels, sampleRate: sampleRate, initial: systemSettings)
        systemEQState = systemEQ.state
        var banks: [EQFilterBank?] = []
        tapEQState = .allocate(capacity: max(tapCount, 1))
        tapHasEQ = .allocate(capacity: max(tapCount, 1))
        for i in 0..<tapCount {
            let settings = i < appEQ.count ? appEQ[i] : nil
            let bank = settings.map { EQFilterBank(channels: channels, sampleRate: sampleRate, initial: $0) }
            banks.append(bank)
            // Taps without an EQ get the system state as a placeholder; tapHasEQ keeps it unused.
            (tapEQState + i).initialize(to: bank?.state ?? systemEQState)
            tapHasEQ[i] = bank == nil ? 0 : 1
        }
        tapEQ = banks
    }

    func set(_ gains: [Float]) {
        for i in 0..<min(tapCount, gains.count) { target[i] = gains[i] }
    }

    deinit {
        for p in [target, current, startGain, endGain, mix, scratch, peaks] { p.deallocate() }
        for p in [tapChannels, tapInterleaved, tapFirstBuffer, outBuffer, outOffset, outStride, tapHasEQ] { p.deallocate() }
        tapEQState.deinitialize(count: tapCount)
        tapEQState.deallocate()
    }
}

/// Captures app audio headed for one output device with Core Audio process taps, applies
/// gain, and plays it to that device through a private aggregate device.
///
/// Taps are tied to the device's first output stream, so apps playing to *other* devices are
/// left alone. Tap 0 is "every process except Knob and the adjusted apps"; taps 1...n are one
/// per adjusted app. All taps mute the original audio on that device, so the only thing the
/// device hears is our mix. Taps are private and owned by this process: if Knob quits or
/// crashes, they vanish and audio goes straight to the device again.
final class TapEngine {
    private(set) var isRunning = false
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = HAL.unknown
    private var procID: AudioDeviceIOProcID?
    private var state: MixState?
    private let queue = DispatchQueue(label: Knob.id + ".audio-io", qos: .userInteractive)
    private let log = Logger(subsystem: Knob.id, category: "engine")

    /// - Parameters:
    ///   - outputDeviceUID: physical device to play to.
    ///   - excludedProcesses: process objects tap 0 must ignore (always include Knob itself).
    ///   - appTaps: one array of process objects per adjusted app.
    ///   - initialGains: one gain per tap: [everything else, app1, app2, ...].
    ///   - systemEQ: EQ on the mix.
    ///   - appEQ: one entry per app tap; nil for apps without EQ.
    func start(outputDeviceUID: String,
               excludedProcesses: [AudioObjectID],
               appTaps: [[AudioObjectID]],
               initialGains: [Float],
               systemEQ: EQSettings,
               appEQ: [EQSettings?]) throws {
        stop()
        do {
            let physical = HAL.device(forUID: outputDeviceUID)
            guard physical != HAL.unknown else { throw HALError(what: "Find output device", status: -1) }
            let deviceStreams = HAL.streamFormats(physical, scope: kAudioObjectPropertyScopeOutput)
            log.info("Output device streams: \(deviceStreams.map(HAL.describe).description, privacy: .public)")
            guard let deviceFormat = deviceStreams.first else { throw HALError(what: "Device has no output stream", status: -1) }

            var tapUIDs: [String] = []
            var taps: [TapInfo] = []

            let othersExcluded = excludedProcesses + appTaps.flatMap { $0 }
            let others = CATapDescription(excludingProcesses: othersExcluded, deviceUID: outputDeviceUID, stream: 0)
            try addTap(others, name: "Knob device", uids: &tapUIDs, taps: &taps)

            for (index, objects) in appTaps.enumerated() {
                let app = CATapDescription(processes: objects, deviceUID: outputDeviceUID, stream: 0)
                try addTap(app, name: "Knob app \(index + 1)", uids: &tapUIDs, taps: &taps)
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

            // render() writes and reads Float32 only. Check the formats the IO proc will see.
            let inFormats = HAL.streamFormats(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outFormats = HAL.streamFormats(aggregate, scope: kAudioObjectPropertyScopeOutput)
            log.info("Aggregate formats: in \(inFormats.map(HAL.describe).description, privacy: .public), out \(outFormats.map(HAL.describe).description, privacy: .public)")
            guard !outFormats.isEmpty, (inFormats + outFormats).allSatisfy(HAL.isFloat32) else {
                throw HALError(what: "Aggregate stream format is not Float32", status: -1)
            }
            // The taps are on the device's first output stream, so they share its sample rate.
            guard taps.allSatisfy({ $0.sampleRate == deviceFormat.mSampleRate }) else {
                throw HALError(what: "Tap sample rate differs from the device (\(deviceFormat.mSampleRate) Hz)", status: -1)
            }

            // render() assumes the tap buffers come LAST in the input buffer list, after the
            // physical device's own input buffers. Refuse to start if the counts don't add up.
            let deviceInputBuffers = HAL.bufferChannels(physical, scope: kAudioObjectPropertyScopeInput).count
            let aggregateInputBuffers = HAL.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeInput).count
            let totalTapBuffers = taps.reduce(0) { $0 + ($1.interleaved ? 1 : $1.channels) }
            log.info("Input buffers: device \(deviceInputBuffers) + taps \(totalTapBuffers), aggregate has \(aggregateInputBuffers)")
            guard aggregateInputBuffers == deviceInputBuffers + totalTapBuffers else {
                throw HALError(what: "Unexpected aggregate input layout (\(aggregateInputBuffers) buffers, expected \(deviceInputBuffers) + \(totalTapBuffers))", status: -1)
            }

            let outputBuffers = HAL.bufferChannels(aggregate, scope: kAudioObjectPropertyScopeOutput)
            guard outputBuffers.reduce(0, +) > 0 else { throw HALError(what: "Aggregate has no output channels", status: -1) }

            let mix = MixState(gains: initialGains,
                               taps: taps.map { MixState.Tap(channels: $0.channels, interleaved: $0.interleaved) },
                               outputBufferChannels: outputBuffers,
                               sampleRate: deviceFormat.mSampleRate,
                               systemEQ: systemEQ,
                               appEQ: [nil] + appEQ)
            state = mix

            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, output, _ in
                TapEngine.render(input: input, output: output, state: mix)
            }, "Create IO proc")
            procID = proc

            try check(AudioDeviceStart(aggregate, proc), "Start aggregate device")
            isRunning = true
            log.info("Engine started: \(tapUIDs.count) taps on stream 0, tap channels \(taps.map(\.channels).description, privacy: .public), output buffers \(outputBuffers.description, privacy: .public), \(Int(deviceFormat.mSampleRate)) Hz, system EQ \(systemEQ.isFlat ? "flat" : "on", privacy: .public), app EQs \(appEQ.compactMap { $0 }.count)")
        } catch {
            stop()
            throw error
        }
    }

    func setGains(_ values: [Float]) {
        state?.set(values)
    }

    /// Main thread. Ramped in over the next IO buffer.
    func setSystemEQ(_ settings: EQSettings) {
        state?.systemEQ.publish(settings)
    }

    /// Main thread. `tap` counts from 1 (tap 0 is "everything else"). Ignored for taps built
    /// without an EQ; turning an app's EQ on or off rebuilds the engine.
    func setAppEQ(tap: Int, _ settings: EQSettings) {
        guard let state, tap > 0, tap < state.tapEQ.count, let bank = state.tapEQ[tap] else { return }
        bank.publish(settings)
    }

    /// Peak input and output levels since the last call, then resets them. Main thread only.
    func takePeaks() -> (input: Float, output: Float)? {
        guard let state else { return nil }
        let result = (state.peaks[0], state.peaks[1])
        state.peaks[0] = 0
        state.peaks[1] = 0
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
        state = nil
        isRunning = false
    }

    deinit { stop() }

    // MARK: - Setup helpers

    private struct TapInfo { let channels: Int; let interleaved: Bool; let sampleRate: Double }

    private func addTap(_ description: CATapDescription, name: String,
                        uids: inout [String], taps: inout [TapInfo]) throws {
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
        log.info("Tap \(name, privacy: .public): \(HAL.describe(format), privacy: .public)")
        // render() reads Float32 only; anything else would play as noise, so refuse to start.
        guard HAL.isFloat32(format), format.mChannelsPerFrame > 0 else {
            throw HALError(what: "Tap \(name) format is \(HAL.describe(format)), expected Float32", status: -1)
        }
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        taps.append(TapInfo(channels: Int(format.mChannelsPerFrame), interleaved: !nonInterleaved,
                            sampleRate: format.mSampleRate))
    }

    // MARK: - Real-time render (no allocation, no locks, no logging)

    /// For each tap: map its channels onto the device's (tap channel c -> device channel c; a
    /// mono tap feeds the first two channels; a stereo-or-wider tap into a mono device is folded
    /// from its first two channels), run the app's EQ if it has one, and add it to the mix with
    /// its gain ramped linearly over the buffer. Then the system EQ runs on the mix, and the
    /// soft limiter writes it to the output buffers.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: MixState) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outChannels = state.outChannels
        let block = MixState.blockSize
        let mix = state.mix
        let scratch = state.scratch
        guard outChannels > 0, outList.count > 0 else { return }

        // Output frame count from the first output channel's buffer.
        let firstOut = outList[state.outBuffer[0]]
        guard firstOut.mNumberChannels > 0 else { return }
        let frames = Int(firstOut.mDataByteSize) / (Int(firstOut.mNumberChannels) * MemoryLayout<Float>.size)
        guard frames > 0 else { return }

        let base = inList.count - state.totalTapBuffers
        let tapsPresent = base >= 0

        for tap in 0..<state.tapCount {
            state.startGain[tap] = state.current[tap]
            state.endGain[tap] = state.target[tap]
            state.current[tap] = state.endGain[tap]
            if state.tapHasEQ[tap] == 1 { state.tapEQState[tap].beginBuffer() }
        }
        let systemEQ = state.systemEQState
        systemEQ.beginBuffer()

        var inPeak = state.peaks[0]
        var outPeak = state.peaks[1]
        let invFrames = 1 / Float(frames)

        var done = 0
        while done < frames {
            let n = min(block, frames - done)
            for c in 0..<outChannels { memset(mix + c * block, 0, n * MemoryLayout<Float>.size) }

            if tapsPresent {
                for tap in 0..<state.tapCount {
                    let tapChannels = state.tapChannels[tap]
                    let interleaved = state.tapInterleaved[tap] == 1
                    let first = base + state.tapFirstBuffer[tap]
                    guard first + (interleaved ? 1 : tapChannels) <= inList.count else { continue }

                    let firstBuffer = inList[first]
                    let inFrames = interleaved
                        ? Int(firstBuffer.mDataByteSize) / (tapChannels * MemoryLayout<Float>.size)
                        : Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
                    let count = min(n, inFrames - done)
                    guard count > 0 else { continue }

                    // 1. Map the tap's channels onto device channels, into scratch.
                    let feeds = tapChannels == 1 ? min(2, outChannels) : min(tapChannels, outChannels)
                    var fed = 0
                    for c in 0..<feeds {
                        let source = tapChannels == 1 ? 0 : c
                        let src: UnsafeMutablePointer<Float>
                        let stride: Int
                        if interleaved {
                            guard let data = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else { break }
                            src = data + source
                            stride = tapChannels
                        } else {
                            guard let data = inList[first + source].mData?.assumingMemoryBound(to: Float.self) else { break }
                            src = data
                            stride = 1
                        }
                        let dst = scratch + c * block
                        // Mono device fed by a stereo-or-wider tap: average the tap's first two channels.
                        var second: UnsafeMutablePointer<Float>? = nil
                        if outChannels == 1 && tapChannels >= 2 {
                            second = interleaved ? src + 1 : inList[first + 1].mData?.assumingMemoryBound(to: Float.self)
                        }
                        for i in 0..<count {
                            let frame = done + i
                            var v = src[frame * stride]
                            if let second { v = (v + second[frame * stride]) * 0.5 }
                            inPeak = max(inPeak, abs(v))
                            dst[i] = v
                        }
                        fed = c + 1
                    }
                    guard fed > 0 else { continue }

                    // 2. The app's own EQ, before mixing.
                    if state.tapHasEQ[tap] == 1 {
                        state.tapEQState[tap].process(scratch, channelStride: block, channels: fed, frames: count)
                    }

                    // 3. Add to the mix with the tap's gain.
                    let g0 = state.startGain[tap]
                    let dg = (state.endGain[tap] - g0) * invFrames
                    let gStart = g0 + dg * Float(done)
                    for c in 0..<fed {
                        let src = scratch + c * block
                        let dst = mix + c * block
                        for i in 0..<count { dst[i] += src[i] * (gStart + dg * Float(i)) }
                    }
                }
            }

            // System EQ on the mix (returns at once when Flat).
            systemEQ.process(mix, channelStride: block, channels: outChannels, frames: n)

            // Soft limit into the device buffers. Every output channel is written (zeros if no
            // tap feeds it), so nothing stale is left in the output.
            for c in 0..<outChannels {
                let buffer = outList[state.outBuffer[c]]
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = state.outStride[c]
                let offset = state.outOffset[c]
                let src = mix + c * block
                for i in 0..<n {
                    let v = softLimit(src[i])
                    data[(done + i) * stride + offset] = v
                    outPeak = max(outPeak, abs(v))
                }
            }
            done += n
        }

        state.peaks[0] = inPeak
        state.peaks[1] = outPeak
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
}
