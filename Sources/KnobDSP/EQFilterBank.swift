import Foundation
import KnobAtomics

/// Owns the memory for one EQ (all its channels) and publishes new settings to the IO thread.
/// Create and publish on the main thread; hand `state` to the IO thread.
///
/// Hand-off: two coefficient slots and a generation counter. `publish` writes the slot the
/// reader isn't using, then release-stores the next generation. The reader (`beginBuffer`)
/// acquire-loads the generation, copies that slot, and checks the generation didn't move while
/// it copied; if it did, it keeps the old coefficients and tries again on the next buffer.
/// No locks and no allocation on the IO thread.
public final class EQFilterBank {
    public let state: EQBankState
    public let sampleRate: Double
    private var writerGeneration: UInt64 = 0

    public init(channels: Int, sampleRate: Double, initial: EQSettings) {
        self.sampleRate = sampleRate
        state = EQBankState(channels: max(channels, 1))
        let slot = EQ.slot(for: initial, sampleRate: sampleRate)
        for i in 0..<EQ.slotSize {
            state.current[i] = slot[i]
            state.from[i] = slot[i]
            state.to[i] = slot[i]
        }
    }

    /// Main thread only. Takes effect on the next IO buffer, ramped over that buffer.
    public func publish(_ settings: EQSettings) {
        let slot = EQ.slot(for: settings, sampleRate: sampleRate)
        // Order the previous generation store before we start overwriting the other slot.
        knob_fence_full()
        let next = writerGeneration + 1
        let target = state.slots + Int(next & 1) * EQ.slotSize
        for i in 0..<EQ.slotSize { target[i] = slot[i] }
        knob_store_release(state.generation, next)
        writerGeneration = next
    }

    deinit { state.deallocate() }
}

/// The IO thread's view of one EQ: raw pointers only, so copying it never retains anything.
public struct EQBankState {
    public let channels: Int
    let slots: UnsafeMutablePointer<Float>       // 2 × slotSize, written by the main thread
    let generation: UnsafeMutablePointer<UInt64> // published generation
    let seen: UnsafeMutablePointer<UInt64>       // last generation the reader took
    let incoming: UnsafeMutablePointer<Float>    // reader's copy of a slot, before validation
    let current: UnsafeMutablePointer<Float>     // coefficients in use
    let from: UnsafeMutablePointer<Float>        // ramp start
    let to: UnsafeMutablePointer<Float>          // ramp end
    let ramping: UnsafeMutablePointer<Int>       // 1 while the next process() call ramps
    let history: UnsafeMutablePointer<Float>     // per channel, per band: x1 x2 y1 y2

    init(channels: Int) {
        self.channels = channels
        slots = .allocate(capacity: 2 * EQ.slotSize)
        slots.initialize(repeating: 0, count: 2 * EQ.slotSize)
        generation = .allocate(capacity: 1); generation.initialize(to: 0)
        seen = .allocate(capacity: 1); seen.initialize(to: 0)
        incoming = .allocate(capacity: EQ.slotSize); incoming.initialize(repeating: 0, count: EQ.slotSize)
        current = .allocate(capacity: EQ.slotSize); current.initialize(repeating: 0, count: EQ.slotSize)
        from = .allocate(capacity: EQ.slotSize); from.initialize(repeating: 0, count: EQ.slotSize)
        to = .allocate(capacity: EQ.slotSize); to.initialize(repeating: 0, count: EQ.slotSize)
        ramping = .allocate(capacity: 1); ramping.initialize(to: 0)
        history = .allocate(capacity: channels * EQ.bandCount * 4)
        history.initialize(repeating: 0, count: channels * EQ.bandCount * 4)
    }

    func deallocate() {
        slots.deallocate(); generation.deallocate(); seen.deallocate(); incoming.deallocate()
        current.deallocate(); from.deallocate(); to.deallocate(); ramping.deallocate(); history.deallocate()
    }

    // MARK: - Real-time (no allocation, no locks, no logging)

    /// Call once per IO buffer, before `process`. Picks up newly published coefficients.
    @inline(__always)
    public func beginBuffer() {
        let g = knob_load_acquire(generation)
        guard g != seen.pointee else { return }
        let slot = slots + Int(g & 1) * EQ.slotSize
        for i in 0..<EQ.slotSize { incoming[i] = slot[i] }
        knob_fence_acquire()
        // The writer published again while we copied, so the slot may be half-written.
        // Keep the old coefficients; the newer generation is picked up next buffer.
        guard knob_load_acquire(generation) == g else { return }
        seen.pointee = g

        if ramping.pointee == 0 {
            for i in 0..<EQ.slotSize { from[i] = current[i] }
            // The filters were skipped while flat, so their history is stale.
            if current[EQ.flatIndex] != 0 {
                history.update(repeating: 0, count: channels * EQ.bandCount * 4)
            }
        }
        for i in 0..<EQ.slotSize { to[i] = incoming[i] }
        ramping.pointee = 1
    }

    /// Filters `frames` samples of each channel in place. Channel c starts at
    /// `data + c * channelStride`. A pending change ramps linearly over this call.
    /// Interpolating normalised coefficients between two stable filters stays stable (the
    /// stability region for a1, a2 is convex).
    @inline(__always)
    public func process(_ data: UnsafeMutablePointer<Float>, channelStride: Int, channels requested: Int, frames: Int) {
        let channelCount = min(requested, channels)
        guard frames > 0, channelCount > 0 else { return }
        let isRamping = ramping.pointee != 0
        if !isRamping && current[EQ.flatIndex] != 0 { return }   // Flat: untouched, bit for bit
        let inv = 1 / Float(frames)

        // Preamp.
        let p0 = isRamping ? from[EQ.preampIndex] : current[EQ.preampIndex]
        let p1 = isRamping ? to[EQ.preampIndex] : current[EQ.preampIndex]
        if p0 != 1 || p1 != 1 {
            let dp = (p1 - p0) * inv
            for c in 0..<channelCount {
                let d = data + c * channelStride
                for i in 0..<frames { d[i] *= p0 + dp * Float(i + 1) }
            }
        }

        for band in 0..<EQ.bandCount {
            let k = band * EQ.coefficientsPerBand
            if isRamping {
                let a = from + k, b = to + k
                if Self.isIdentity(a) && Self.isIdentity(b) { continue }
                // A band at 0 dB is skipped, so its history is stale; start it clean.
                if Self.isIdentity(a) {
                    for c in 0..<channelCount {
                        (history + (c * EQ.bandCount + band) * 4).update(repeating: 0, count: 4)
                    }
                }
                let d0 = (b[0] - a[0]) * inv, d1 = (b[1] - a[1]) * inv, d2 = (b[2] - a[2]) * inv
                let d3 = (b[3] - a[3]) * inv, d4 = (b[4] - a[4]) * inv
                for c in 0..<channelCount {
                    let h = history + (c * EQ.bandCount + band) * 4
                    var x1 = h[0], x2 = h[1], y1 = h[2], y2 = h[3]
                    let d = data + c * channelStride
                    for i in 0..<frames {
                        let t = Float(i + 1)
                        let x = d[i]
                        let y = (a[0] + d0 * t) * x + (a[1] + d1 * t) * x1 + (a[2] + d2 * t) * x2
                            - (a[3] + d3 * t) * y1 - (a[4] + d4 * t) * y2
                        x2 = x1; x1 = x; y2 = y1; y1 = y
                        d[i] = y
                    }
                    Self.store(h, x1, x2, y1, y2)
                }
            } else {
                let co = current + k
                if Self.isIdentity(co) { continue }
                let b0 = co[0], b1 = co[1], b2 = co[2], a1 = co[3], a2 = co[4]
                for c in 0..<channelCount {
                    let h = history + (c * EQ.bandCount + band) * 4
                    var x1 = h[0], x2 = h[1], y1 = h[2], y2 = h[3]
                    let d = data + c * channelStride
                    for i in 0..<frames {
                        let x = d[i]
                        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                        x2 = x1; x1 = x; y2 = y1; y1 = y
                        d[i] = y
                    }
                    Self.store(h, x1, x2, y1, y2)
                }
            }
        }

        if isRamping {
            for i in 0..<EQ.slotSize { current[i] = to[i] }
            ramping.pointee = 0
        }
    }

    @inline(__always)
    static func isIdentity(_ c: UnsafeMutablePointer<Float>) -> Bool {
        c[0] == 1 && c[1] == 0 && c[2] == 0 && c[3] == 0 && c[4] == 0
    }

    /// Saves filter history, flushing values too small to hear so silence never decays into
    /// denormals.
    @inline(__always)
    static func store(_ h: UnsafeMutablePointer<Float>, _ x1: Float, _ x2: Float, _ y1: Float, _ y2: Float) {
        let tiny: Float = 1e-20
        h[0] = abs(x1) < tiny ? 0 : x1
        h[1] = abs(x2) < tiny ? 0 : x2
        h[2] = abs(y1) < tiny ? 0 : y1
        h[3] = abs(y2) < tiny ? 0 : y2
    }
}
