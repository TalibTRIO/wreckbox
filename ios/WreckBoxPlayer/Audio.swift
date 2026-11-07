import Accelerate
import AVFoundation
import MediaToolbox

// MARK: - EQ

/// The 10-band EQ (±12 dB) and 8 presets shared by every WreckBox app. Everything the phone's own player plays
/// (YouTube streams, phone songs) goes through AudioTap's filters; YouTube's backup page through filters inside the
/// page. (Port of the Mac Player's EQ.)
@MainActor
final class EQ: ObservableObject {
    static let shared = EQ()
    nonisolated static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Club", [4, 3, 2, 0, -1, -1, 0, 2, 3, 3]),
        ("Hip-hop", [5, 4, 1, 2, -1, -1, 1, 0, 2, 3]),
        ("Electronic", [4, 3, 1, 0, -2, 1, 0, 1, 3, 4]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Loudness", [5, 3, 0, 0, -1, 0, -1, 0, 3, 4]),
    ]

    @Published private(set) var gains: [Float]
    @Published private(set) var on: Bool
    @Published private(set) var preset: String
    /// The player passes changes on to YouTube's backup page.
    var onChange: (([Float]) -> Void)?

    /// The gains actually applied: flat when off.
    var effective: [Float] { on ? gains : Array(repeating: 0, count: 10) }

    private init() {
        let d = UserDefaults.standard
        let saved = (d.array(forKey: "eqGains") as? [NSNumber])?.map(\.floatValue)
        gains = saved?.count == 10 ? saved! : Array(repeating: 0, count: 10)
        on = d.object(forKey: "eqOn") as? Bool ?? true
        preset = d.string(forKey: "eqPreset") ?? "Flat"
        AudioTap.setGains(effective)
    }

    func setOn(_ v: Bool) { on = v; changed() }

    func choose(_ name: String) {
        guard let p = Self.presets.first(where: { $0.0 == name }) else { return }
        gains = p.1; preset = name; on = true
        changed()
    }

    func setBand(_ i: Int, _ db: Float) {
        guard gains.indices.contains(i) else { return }
        gains[i] = max(-12, min(12, db)); preset = "Custom"; on = true
        changed()
    }

    private func changed() {
        let d = UserDefaults.standard
        d.set(gains, forKey: "eqGains"); d.set(on, forKey: "eqOn"); d.set(preset, forKey: "eqPreset")
        AudioTap.setGains(effective)
        onChange?(effective)
        WidgetBridge.shared.changed()
    }
}

// MARK: - Levels

/// The music's real spectrum for the dot displays: 8 log-spaced bands (60 Hz – 16 kHz), 0…1, measured from the audio
/// as it plays (AudioTap). Only measured while some display wants it.
@MainActor
final class Levels: ObservableObject {
    static let shared = Levels()
    static let count = 8
    @Published private(set) var bands: [Float]?
    private var users = 0
    var wanted: Bool { users > 0 }

    func want() { users += 1; AudioTap.measuring = true }
    func unwant() { users = max(0, users - 1); if users == 0 { AudioTap.measuring = false; bands = nil } }
    func clear() { bands = nil }
    func set(_ b: [Float]) { if wanted, b.count == Self.count { bands = b } }
}

// MARK: - The tap

/// Sits inside the phone's player (an MTAudioProcessingTap on each song): runs the EQ's filters on the audio and,
/// while a display wants it, measures the spectrum. Works the same for YouTube streams and phone songs.
final class AudioTap: @unchecked Sendable {
    /// The gains every tap uses (set from the main thread, read on the audio thread).
    nonisolated(unsafe) private static var gains = [Float](repeating: 0, count: 10)
    nonisolated(unsafe) private static var version = 0
    nonisolated(unsafe) static var measuring = false
    private static let lock = NSLock()

    static func setGains(_ g: [Float]) {
        lock.lock(); gains = g; version += 1; lock.unlock()
    }

    private static func current() -> ([Float], Int) {
        lock.lock(); defer { lock.unlock() }
        return (gains, version)
    }

    /// The audio mix that puts a tap on the asset's audio — set on the item before it plays (adding it mid-song makes
    /// the player rebuild its audio, which stalled streams and ended files early).
    /// A YouTube stream has one track, id 1: no need to read its header first (that cost seconds over the network).
    static func mix(for asset: AVAsset, trackID known: CMPersistentTrackID? = nil) async -> AVAudioMix? {
        var trackID = known ?? kCMPersistentTrackID_Invalid
        if known == nil {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
            trackID = track.trackID
        }
        let ctx = Unmanaged.passRetained(AudioTap())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: ctx.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<AudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in Unmanaged<AudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee) },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<AudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(buffers, Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else {
            ctx.release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters()
        params.trackID = trackID
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: audio thread

    private var sampleRate = 44_100.0
    private var floatPCM = false
    /// Per channel, per band: the filter's memory (x1, x2, y1, y2), in one flat block (nothing allocated while playing).
    private var state: [Float] = []
    private var channels = 0
    private var coeffs: [(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float)] = []
    private var coeffsVersion = -1
    private var active = false

    private func prepare(_ f: AudioStreamBasicDescription) {
        sampleRate = f.mSampleRate
        floatPCM = f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
            && f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        channels = Int(max(1, f.mChannelsPerFrame))
        state = [Float](repeating: 0, count: channels * 10 * 4)
        coeffsVersion = -1
        let line = "audio tap: \(Int(f.mSampleRate)) Hz, \(channels) ch, \(floatPCM ? "EQ ready" : "format not supported, plays flat")"
        DispatchQueue.main.async { MainActor.assumeIsolated { Log.shared.write(line) } }
    }

    /// RBJ cookbook filters: low shelf at 32 Hz, peaks in between, high shelf at 16 kHz (Q 1.1, like the page's).
    private func design(_ g: [Float]) {
        coeffs = EQ.frequencies.enumerated().map { i, f in
            let a = pow(10, Double(g[i]) / 40)
            let w0 = 2 * Double.pi * min(Double(f), sampleRate * 0.45) / sampleRate
            let cw = cos(w0), sw = sin(w0)
            var b0, b1, b2, a0, a1, a2: Double
            if i == 0 || i == 9 {
                let alpha = sw / 2 * sqrt(2.0) // shelf slope 1
                let sa = 2 * sqrt(a) * alpha
                if i == 0 {
                    b0 = a * ((a + 1) - (a - 1) * cw + sa); b1 = 2 * a * ((a - 1) - (a + 1) * cw); b2 = a * ((a + 1) - (a - 1) * cw - sa)
                    a0 = (a + 1) + (a - 1) * cw + sa; a1 = -2 * ((a - 1) + (a + 1) * cw); a2 = (a + 1) + (a - 1) * cw - sa
                } else {
                    b0 = a * ((a + 1) + (a - 1) * cw + sa); b1 = -2 * a * ((a - 1) + (a + 1) * cw); b2 = a * ((a + 1) + (a - 1) * cw - sa)
                    a0 = (a + 1) - (a - 1) * cw + sa; a1 = 2 * ((a - 1) - (a + 1) * cw); a2 = (a + 1) - (a - 1) * cw - sa
                }
            } else {
                let alpha = sw / (2 * 1.1)
                b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
                a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
            }
            return (Float(b0 / a0), Float(b1 / a0), Float(b2 / a0), Float(a1 / a0), Float(a2 / a0))
        }
        active = g.contains { $0 != 0 }
    }

    private func process(_ list: UnsafeMutablePointer<AudioBufferList>, _ frames: Int) {
        guard floatPCM, frames > 0 else { return }
        let (g, v) = Self.current()
        if v != coeffsVersion { design(g); coeffsVersion = v }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if active {
            state.withUnsafeMutableBufferPointer { st in
                for (c, buf) in buffers.enumerated() where c < channels {
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for b in 0..<coeffs.count {
                        let k = coeffs[b]
                        let o = (c * 10 + b) * 4
                        var x1 = st[o], x2 = st[o + 1], y1 = st[o + 2], y2 = st[o + 3]
                        for i in 0..<frames {
                            let x = p[i]
                            let y = k.b0 * x + k.b1 * x1 + k.b2 * x2 - k.a1 * y1 - k.a2 * y2
                            x2 = x1; x1 = x; y2 = y1; y1 = y
                            p[i] = y
                        }
                        st[o] = x1; st[o + 1] = x2; st[o + 2] = y1; st[o + 3] = y2
                    }
                }
            }
            // Boosting can push past full scale: keep it from clipping.
            for buf in buffers {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var lo: Float = -1, hi: Float = 1
                vDSP_vclip(p, 1, &lo, &hi, p, 1, vDSP_Length(frames))
            }
        }
        if Self.measuring { measure(buffers, frames) }
    }

    // Spectrum for the dot displays, ~10 a second.
    private var smooth = [Float](repeating: 0, count: 8)
    private var lastMeasure = Date.distantPast
    private let n = 2048
    private lazy var fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
    private var ring = [Float](repeating: 0, count: 2048)
    private var ringAt = 0

    private func measure(_ buffers: UnsafeMutableAudioBufferListPointer, _ frames: Int) {
        // Keep the last 2048 samples (mono).
        let chans = buffers.prefix(2).compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
        guard !chans.isEmpty else { return }
        for i in 0..<frames {
            var v: Float = 0
            for c in chans { v += c[i] }
            ring[ringAt] = v
            ringAt = (ringAt + 1) % n
        }
        let now = Date()
        guard now.timeIntervalSince(lastMeasure) > 0.1, let fft else { return }
        lastMeasure = now
        var mono = Array(ring[ringAt...] + ring[..<ringAt])
        mono = vDSP.multiply(mono, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2), mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                mono.withUnsafeBufferPointer { mp in
                    mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        let binHz = Float(sampleRate) / Float(n)
        for b in 0..<8 {
            let lo = 60 * pow(16000 / 60, Float(b) / 8), hi = 60 * pow(16000 / 60, Float(b + 1) / 8)
            let i0 = max(1, Int(lo / binHz)), i1 = max(i0 + 1, min(n / 2, Int(hi / binHz)))
            let db = 20 * log10(max((mags[i0..<i1].max() ?? 0) / Float(n), 1e-7))
            let v = max(0, min(1, (db + 70) / 60))
            smooth[b] = v > smooth[b] ? v : smooth[b] * 0.6 + v * 0.4
        }
        let snap = smooth
        DispatchQueue.main.async { MainActor.assumeIsolated { Levels.shared.set(snap) } }
    }
}
