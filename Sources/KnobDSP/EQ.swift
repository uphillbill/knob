import Foundation

/// 10-band graphic EQ: low shelf at 31 Hz, peaking filters from 62 Hz to 8 kHz, high shelf at
/// 16 kHz, plus a preamp. Everything here runs on the main thread; the real-time side is
/// `EQFilterBank`.
public enum EQ {
    public static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = 10
    public static let bandRange: ClosedRange<Float> = -12...12
    public static let preampRange: ClosedRange<Float> = -12...6
    /// Peaking filter Q (about 1 octave wide, so neighbouring bands blend smoothly).
    public static let q = 1.41
    /// Shelf slope (RBJ "S"); 1 is the steepest slope without overshoot.
    public static let shelfSlope = 1.0

    public static func label(forBand band: Int) -> String {
        let f = frequencies[band]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    // MARK: - Coefficient slots (the layout EQFilterBank reads)

    static let coefficientsPerBand = 5                         // b0 b1 b2 a1 a2, normalised by a0
    static let preampIndex = bandCount * coefficientsPerBand   // linear preamp gain
    static let flatIndex = preampIndex + 1                     // 1 when the whole bank is a no-op
    static let slotSize = flatIndex + 1

    /// Everything the real-time bank needs for one setting, as a flat Float array.
    static func slot(for settings: EQSettings, sampleRate: Double) -> [Float] {
        var slot = [Float](repeating: 0, count: slotSize)
        let flat = settings.isFlat
        for band in 0..<bandCount {
            let gain = flat ? 0 : Double(settings.bands[band])
            let c = Biquad.band(band, gainDB: gain, sampleRate: sampleRate)
            let k = band * coefficientsPerBand
            slot[k] = Float(c.b0); slot[k + 1] = Float(c.b1); slot[k + 2] = Float(c.b2)
            slot[k + 3] = Float(c.a1); slot[k + 4] = Float(c.a2)
        }
        slot[preampIndex] = flat ? 1 : powf(10, settings.preamp / 20)
        slot[flatIndex] = flat ? 1 : 0
        return slot
    }

    // MARK: - Frequency response (for the EQ window and the checks)

    /// Total response in dB at one frequency, preamp included.
    public static func responseDB(_ settings: EQSettings, at frequency: Double, sampleRate: Double = 48000) -> Double {
        guard !settings.isFlat else { return 0 }
        var db = Double(settings.preamp)
        for band in 0..<bandCount {
            db += Biquad.band(band, gainDB: Double(settings.bands[band]), sampleRate: sampleRate)
                .responseDB(at: frequency, sampleRate: sampleRate)
        }
        return db
    }

    /// Largest boost anywhere from 20 Hz to 20 kHz, preamp included. Above 0 dB, loud audio can
    /// reach the soft limiter.
    public static func peakDB(_ settings: EQSettings, sampleRate: Double = 48000) -> Double {
        guard !settings.isFlat else { return 0 }
        let points = 160
        var peak = -Double.infinity
        for i in 0..<points {
            let f = 20 * pow(1000, Double(i) / Double(points - 1))
            peak = max(peak, responseDB(settings, at: f, sampleRate: sampleRate))
        }
        return peak
    }
}

/// Band gains in dB plus a preamp in dB.
public struct EQSettings: Equatable {
    public var bands: [Float]
    public var preamp: Float

    public init(bands: [Float], preamp: Float = 0) {
        var b = Array(bands.prefix(EQ.bandCount))
        while b.count < EQ.bandCount { b.append(0) }
        self.bands = b.map { min(max($0, EQ.bandRange.lowerBound), EQ.bandRange.upperBound) }
        self.preamp = min(max(preamp, EQ.preampRange.lowerBound), EQ.preampRange.upperBound)
    }

    public static let flat = EQSettings(bands: [])

    /// Flat means "skip the EQ entirely", so tiny slider leftovers count as flat.
    public var isFlat: Bool { abs(preamp) < 0.05 && bands.allSatisfy { abs($0) < 0.05 } }

    /// Stored form: 10 band gains followed by the preamp.
    public var stored: [Double] { bands.map(Double.init) + [Double(preamp)] }

    public init?(stored: Any?) {
        guard let values = stored as? [Double], values.count == EQ.bandCount + 1 else { return nil }
        self.init(bands: values.prefix(EQ.bandCount).map(Float.init), preamp: Float(values[EQ.bandCount]))
    }

    /// Same settings to within 0.05 dB (used to show which preset is selected).
    public func matches(_ other: EQSettings) -> Bool {
        abs(preamp - other.preamp) < 0.05 && zip(bands, other.bands).allSatisfy { abs($0 - $1) < 0.05 }
    }
}

public struct EQPreset: Identifiable, Equatable {
    public let name: String
    public let settings: EQSettings
    public let isBuiltIn: Bool
    public var id: String { name }

    public init(name: String, settings: EQSettings, isBuiltIn: Bool = false) {
        self.name = name
        self.settings = settings
        self.isBuiltIn = isBuiltIn
    }

    /// Built-in presets in menu order: tone fixes first, then music styles.
    ///
    /// Shapes follow the classic player presets: Apple's iTunes/Music presets (same 10 bands as
    /// Knob) and, for Reggae and Techno, Winamp's (interpolated onto these bands). They're played
    /// at 1.5× the original strength, because the originals are subtle enough that several sound
    /// alike. Loudness and Night are Knob's own.
    ///
    /// Each preamp is computed so the curve's highest point sits at 0 dB, so a preset never pushes
    /// loud audio into the limiter. Boosting presets therefore play quieter; turn Knob up to match.
    public static let builtIn: [EQPreset] = tone + music

    /// Index in `builtIn` where the music styles start (menus put a divider there).
    public static var musicStart: Int { tone.count }

    private static func preset(_ name: String, _ bands: [Float]) -> EQPreset {
        let shape = EQSettings(bands: bands)
        let peak = EQ.peakDB(shape)
        let preamp = peak > 0 ? max(EQ.preampRange.lowerBound, -Float((peak * 2).rounded(.up)) / 2) : 0
        return EQPreset(name: name, settings: EQSettings(bands: bands, preamp: preamp), isBuiltIn: true)
    }

    //                                 31    62   125   250   500    1k    2k    4k    8k   16k
    private static let tone: [EQPreset] = [
        EQPreset(name: "Flat", settings: .flat, isBuiltIn: true),
        preset("Bass boost",       [  8,  6.5,    5,    4,    2,    0,    0,    0,    0,    0]),
        preset("Bass cut",         [ -8, -6.5,   -5,   -4,   -2,    0,    0,    0,    0,    0]),
        preset("Treble boost",     [  0,    0,    0,    0,    0,    2,  3.5,    5,  6.5,    8]),
        preset("Treble cut",       [  0,    0,    0,    0,    0,   -2, -3.5,   -5, -6.5,   -8]),
        preset("Vocal boost",      [ -2, -4.5, -4.5,    2,  5.5,  5.5,  4.5,    2,    0,   -2]),
        preset("Dialogue boost",   [ -5,   -1,    0,    1,    5,    7,    7,  6.5,    4,    0]),
        preset("Small speakers",   [  8,  6.5,    5,    4,    2,    0,   -2,   -4,   -5, -6.5]),
        preset("Loudness",         [  9,  7.5,  4.5,  1.5,    0, -1.5,    0,    3,    6,  7.5]),
        preset("Night",            [-10,   -8,   -5,   -2,    0,    1,    2,    1,   -2,   -4]),
    ]

    //                                 31    62   125   250   500    1k    2k    4k    8k   16k
    private static let music: [EQPreset] = [
        preset("Acoustic",         [7.5,  7.5,    6,  1.5,  3.5,  2.5,    5,    6,  5.5,  3.5]),
        preset("Classical",        [  7,  5.5,  4.5,    4,   -2,   -2,    0,  3.5,    5,  5.5]),
        preset("Dance",            [5.5,    9,    7,    0,    3,  5.5,    8,    7,  5.5,    0]),
        preset("Deep",             [7.5,  5.5,  2.5,  1.5,  4.5,    4,    2, -3.5, -5.5,   -7]),
        preset("Electronic",       [6.5,  5.5,    2,    0, -3.5,  3.5,  1.5,    2,    6,    7]),
        preset("Hip-hop & Rap",    [7.5,  6.5,    2,  4.5, -1.5, -1.5,    2,   -1,    3,  4.5]),
        preset("Jazz",             [  6,  4.5,    2,  3.5,   -2,   -2,    0,    2,  4.5,  5.5]),
        preset("Latin",            [  7,  4.5,    0,    0,   -2,   -2,   -2,    0,  4.5,    7]),
        preset("Lounge",           [-4.5,  -2,   -1,    2,    6,   -4,    0,   -2,    3,  1.5]),
        preset("Piano",            [4.5,    3,    0,    4,  4.5,    2,    5,    7,  4.5,    5]),
        preset("Pop",              [ -2, -1.5,    0,    3,    6,    6,    3,    0, -1.5,   -2]),
        preset("R&B",              [  4,  9.5,  7.5,    2, -3.5,   -2,  3.5,    4,  4.5,  5.5]),
        preset("Reggae",           [  0,    0,    0, -0.5,   -5,    0,  3.5,    6,  3.5,    0]),
        preset("Rock",             [7.5,    6,  4.5,    2,   -1, -1.5,    1,    4,    5,    7]),
        preset("Techno",           [  7,    7,  5.5,    2,   -4,   -5,   -2,    3,  7.5,    8]),
    ]
}

/// One second-order section, normalised so a0 = 1 (RBJ Audio EQ Cookbook formulas).
public struct Biquad: Equatable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    public init(b0: Double = 1, b1: Double = 0, b2: Double = 0, a1: Double = 0, a2: Double = 0) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public static let identity = Biquad()

    /// The filter for one EQ band. 0 dB gives the exact identity, so the bank can skip it.
    public static func band(_ band: Int, gainDB: Double, sampleRate: Double) -> Biquad {
        guard abs(gainDB) >= 0.01 else { return .identity }
        // Keep the corner below Nyquist (16 kHz would sit right at Nyquist at 32 kHz).
        let f = min(EQ.frequencies[band], sampleRate * 0.45)
        switch band {
        case 0: return lowShelf(frequency: f, gainDB: gainDB, sampleRate: sampleRate)
        case EQ.bandCount - 1: return highShelf(frequency: f, gainDB: gainDB, sampleRate: sampleRate)
        default: return peaking(frequency: f, gainDB: gainDB, q: EQ.q, sampleRate: sampleRate)
        }
    }

    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        return normalised(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                          a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    public static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let (a, cosw, beta) = shelfTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate)
        return normalised(b0: a * ((a + 1) - (a - 1) * cosw + beta),
                          b1: 2 * a * ((a - 1) - (a + 1) * cosw),
                          b2: a * ((a + 1) - (a - 1) * cosw - beta),
                          a0: (a + 1) + (a - 1) * cosw + beta,
                          a1: -2 * ((a - 1) + (a + 1) * cosw),
                          a2: (a + 1) + (a - 1) * cosw - beta)
    }

    public static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let (a, cosw, beta) = shelfTerms(frequency: frequency, gainDB: gainDB, sampleRate: sampleRate)
        return normalised(b0: a * ((a + 1) + (a - 1) * cosw + beta),
                          b1: -2 * a * ((a - 1) + (a + 1) * cosw),
                          b2: a * ((a + 1) + (a - 1) * cosw - beta),
                          a0: (a + 1) - (a - 1) * cosw + beta,
                          a1: 2 * ((a - 1) - (a + 1) * cosw),
                          a2: (a + 1) - (a - 1) * cosw - beta)
    }

    /// A, cos(w0) and 2·sqrt(A)·alpha for the shelf formulas.
    private static func shelfTerms(frequency: Double, gainDB: Double, sampleRate: Double) -> (Double, Double, Double) {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / 2 * sqrt((a + 1 / a) * (1 / EQ.shelfSlope - 1) + 2)
        return (a, cos(w), 2 * sqrt(a) * alpha)
    }

    private static func normalised(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response in dB at one frequency.
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
        let mag2 = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        return 10 * log10(mag2)
    }

    /// Both poles strictly inside the unit circle (the stability triangle for a1, a2).
    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }
}
