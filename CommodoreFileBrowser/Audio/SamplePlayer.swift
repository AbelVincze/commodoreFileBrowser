import AVFoundation
import Combine
import os

/// Plays an 8SVX sample.
///
/// The other two players drive a C emulator a buffer at a time; there is no
/// engine here at all, only a cursor walking a block of samples. What is kept
/// from `ModulePlayer` is the discipline around it: the render block touches
/// nothing but plain pointers, never blocks on the lock, and ramps its gain
/// across the buffer so a volume drag cannot click.
///
/// The node is built at the sample's own rate rather than at 44100, so the
/// mixer does the resampling and nothing here has to. That is also why there
/// is no video export: the exporter counts its frames in SID samples per
/// second, and a 16726 Hz sound would come out of step with its own picture.
final class SamplePlayer: ObservableObject {

    @Published private(set) var sound: SampledSound?
    @Published private(set) var isPlaying = false
    /// Seconds in, for the clock and the slider.
    @Published private(set) var position: Double = 0
    @Published var looping = true {
        didSet { loopOn.pointee = looping && sound?.loop != nil }
    }
    @Published var volume: Double = 1 { didSet { applyGain() } }
    @Published var errorMessage: String?

    /// Which sheet the sample belongs to, so the sheet going away can tell
    /// itself apart from the one arriving when files are stepped through.
    private(set) var owner: UUID?

    var duration: Double { sound?.duration ?? 0 }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var ticker: Timer?
    private var rate: Double = 44100

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// The sound itself, and where in it the render block has got to.
    private var samples: UnsafeMutablePointer<Int16>?
    private let count: UnsafeMutablePointer<Int>
    private let cursor: UnsafeMutablePointer<Int>
    private let loopStart: UnsafeMutablePointer<Int>
    private let loopEnd: UnsafeMutablePointer<Int>
    private let loopOn: UnsafeMutablePointer<Bool>
    private let ended: UnsafeMutablePointer<Bool>
    private let targetGain: UnsafeMutablePointer<Float>
    private let currentGain: UnsafeMutablePointer<Float>

    static let scopeLength = 2048
    private let scopeRing: UnsafeMutablePointer<Int16>
    private let scopePosition: UnsafeMutablePointer<Int>
    private let scopeOn: UnsafeMutablePointer<Bool>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        count = .allocate(capacity: 1);      count.initialize(to: 0)
        cursor = .allocate(capacity: 1);     cursor.initialize(to: 0)
        loopStart = .allocate(capacity: 1);  loopStart.initialize(to: 0)
        loopEnd = .allocate(capacity: 1);    loopEnd.initialize(to: 0)
        loopOn = .allocate(capacity: 1);     loopOn.initialize(to: false)
        ended = .allocate(capacity: 1);      ended.initialize(to: false)
        targetGain = .allocate(capacity: 1); targetGain.initialize(to: 1)
        currentGain = .allocate(capacity: 1); currentGain.initialize(to: 1)
        scopeRing = .allocate(capacity: Self.scopeLength)
        scopeRing.initialize(repeating: 0, count: Self.scopeLength)
        scopePosition = .allocate(capacity: 1); scopePosition.initialize(to: 0)
        scopeOn = .allocate(capacity: 1);       scopeOn.initialize(to: false)
    }

    deinit {
        ticker?.invalidate()
        engine.stop()
        samples?.deallocate()
        count.deallocate(); cursor.deallocate()
        loopStart.deallocate(); loopEnd.deallocate(); loopOn.deallocate()
        ended.deallocate()
        targetGain.deallocate(); currentGain.deallocate()
        scopeRing.deallocate(); scopePosition.deallocate(); scopeOn.deallocate()
        lock.deallocate()
    }

    // MARK: - Loading

    /// Hand a sample to the player. Detaching the node rather than reusing it
    /// is what lets the next sample run at its own rate: a source node's format
    /// is fixed when it is made.
    func load(_ new: SampledSound, owner id: UUID) {
        pause()
        detachSource()

        os_unfair_lock_lock(lock)
        samples?.deallocate()
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: max(1, new.frames.count))
        new.frames.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: new.frames.count) }
        samples = buffer
        count.pointee = new.frames.count
        cursor.pointee = 0
        loopStart.pointee = new.loop?.lowerBound ?? 0
        loopEnd.pointee = new.loop?.upperBound ?? new.frames.count
        loopOn.pointee = looping && new.loop != nil
        ended.pointee = false
        os_unfair_lock_unlock(lock)

        sound = new
        rate = new.sampleRate
        owner = id
        position = 0
        errorMessage = nil
    }

    func unload() {
        pause()
        detachSource()
        os_unfair_lock_lock(lock)
        samples?.deallocate()
        samples = nil
        count.pointee = 0
        cursor.pointee = 0
        os_unfair_lock_unlock(lock)
        sound = nil
        owner = nil
        position = 0
    }

    // MARK: - Transport

    func play() {
        guard sound != nil else { return }
        // A one-shot that has run out starts again rather than doing nothing,
        // which is what pressing play on a finished sound plainly means.
        if ended.pointee { rewind() }
        if source == nil { attachSource() }
        do {
            if !engine.isRunning { try engine.start() }
            isPlaying = true
            startTicking()
        } catch {
            errorMessage = "Could not start audio: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func pause() {
        ticker?.invalidate(); ticker = nil
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    func stop() {
        pause()
        rewind()
        position = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard rate > 0 else { return }
        let frame = Int(max(0, min(seconds, duration)) * rate)
        os_unfair_lock_lock(lock)
        cursor.pointee = min(frame, max(0, count.pointee - 1))
        ended.pointee = false
        os_unfair_lock_unlock(lock)
        position = Double(frame) / rate
    }

    private func rewind() {
        os_unfair_lock_lock(lock)
        cursor.pointee = 0
        ended.pointee = false
        os_unfair_lock_unlock(lock)
    }

    private func applyGain() {
        targetGain.pointee = Float(max(0, min(1, volume)))
    }

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.position = self.rate > 0 ? Double(self.cursor.pointee) / self.rate : 0
            // A one-shot stops itself; a looping instrument never gets here.
            if self.ended.pointee { self.pause(); self.position = self.duration }
        }
    }

    // MARK: - Oscilloscope

    func setScope(enabled: Bool) {
        scopeOn.pointee = enabled
        guard enabled else { return }
        scopeRing.update(repeating: 0, count: Self.scopeLength)
        scopePosition.pointee = 0
    }

    /// One trace: the sound is mono, so there is no second one to draw. Read
    /// without the lock, the same trade the other two players make — a torn
    /// read costs one ragged frame and is not worth stalling audio for.
    func scopeSnapshot() -> [[Int16]] {
        var out = [Int16](repeating: 0, count: Self.scopeLength)
        let start = scopePosition.pointee
        for i in 0..<Self.scopeLength {
            out[i] = scopeRing[(start + i) % Self.scopeLength]
        }
        return [out]
    }

    // MARK: - The audio graph

    private func detachSource() {
        if let source {
            engine.detach(source)
            self.source = nil
        }
    }

    private func attachSource() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            errorMessage = "\(Int(rate)) Hz is not a rate this machine will play"
            return
        }

        let lock = self.lock
        let data = self.samples
        let total = self.count
        let at = self.cursor
        let from = self.loopStart
        let to = self.loopEnd
        let repeating = self.loopOn
        let finished = self.ended
        let wanted = self.targetGain
        let reached = self.currentGain
        let ring = self.scopeRing
        let ringPosition = self.scopePosition
        let capturing = self.scopeOn

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

            guard os_unfair_lock_trylock(lock) else {
                for i in 0..<frames { out[i] = 0 }
                return noErr
            }
            defer { os_unfair_lock_unlock(lock) }

            guard let data, total.pointee > 0 else {
                for i in 0..<frames { out[i] = 0 }
                return noErr
            }

            let level = wanted.pointee
            var gain = reached.pointee
            let ramp = (level - gain) / Float(frames)
            var p = at.pointee
            var ringAt = ringPosition.pointee
            let capture = capturing.pointee

            for i in 0..<frames {
                var sample: Int16 = 0
                if p < total.pointee {
                    sample = data[p]
                    p += 1
                    // The loop is a window inside the sound, not the whole of
                    // it: a one-shot attack plays once and then the tail runs
                    // round for as long as the note is held.
                    if repeating.pointee, p >= to.pointee, to.pointee > from.pointee {
                        p = from.pointee
                    }
                } else {
                    finished.pointee = true
                }
                if capture {
                    ring[ringAt] = sample
                    ringAt = (ringAt + 1) % SamplePlayer.scopeLength
                }
                out[i] = Float(sample) / 32768.0 * gain
                gain += ramp
            }

            at.pointee = p
            ringPosition.pointee = ringAt
            reached.pointee = level
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }
}
