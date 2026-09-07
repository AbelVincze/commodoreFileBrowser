import Foundation
import AVFoundation

/// Drives the vendored libopenmpt engine from an audio render callback.
///
/// Shaped like `SIDPlayer` next door, and for the same reason: the engine is
/// one global machine, so loading a module replaces whatever was playing. What
/// differs is that a module is stereo, knows how long it runs and can be seeked
/// — a tracker file carries its whole song rather than a routine to call.
final class ModulePlayer: ObservableObject {

    static let sampleRate = 44100.0

    @Published private(set) var isPlaying = false
    @Published private(set) var module: Module?

    /// What the engine made of the file once it was open: these come from
    /// inside it, and are what the sheet shows.
    @Published private(set) var type = ""
    @Published private(set) var tracker = ""
    @Published private(set) var innerTitle = ""
    @Published private(set) var channels = 0
    @Published private(set) var instruments = 0
    @Published private(set) var samples = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var subsongs = 0

    /// Where playback has got to, in seconds. Read from the engine on the main
    /// thread rather than counted in the render block: libopenmpt keeps the
    /// position itself, and it moves with seeks and pattern jumps.
    @Published private(set) var position: Double = 0

    /// Output level, 0 to 1.
    @Published var volume: Double = 1 { didSet { applyGain() } }
    /// Start again at the end rather than stopping.
    @Published var repeats = false { didSet { apply { cmod_set_repeat(repeats ? 1 : 0) } } }
    /// 100 is the stereo the file asks for, 0 is mono. Amiga modules pan hard
    /// left and right by design, which is tiring on headphones.
    @Published var stereoSeparation: Double = 100 {
        didSet { apply { cmod_set_stereo_separation(Int32(stereoSeparation)) } }
    }
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var ticker: Timer?

    /// The render block runs on the audio thread while the UI reconfigures on
    /// the main one. It never blocks: failing to take the lock means a buffer
    /// of silence rather than a stalled audio thread.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Interleaved stereo, so two shorts per frame.
    private let scratchFrames = 4096
    private let scratch: UnsafeMutablePointer<Int16>
    /// Set by the render block when the module runs out, read by the ticker.
    private let ended: UnsafeMutablePointer<Bool>
    private let targetGain: UnsafeMutablePointer<Float>
    private let currentGain: UnsafeMutablePointer<Float>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
        ended = .allocate(capacity: 1)
        ended.initialize(to: false)
        targetGain = .allocate(capacity: 1)
        targetGain.initialize(to: 1)
        currentGain = .allocate(capacity: 1)
        currentGain.initialize(to: 1)
    }

    deinit {
        ticker?.invalidate()
        engine.stop()
        scratch.deallocate()
        ended.deallocate()
        targetGain.deallocate()
        currentGain.deallocate()
        lock.deallocate()
    }

    // MARK: - Transport

    /// Hand a module to the engine. Returns false when libopenmpt will not have
    /// it, which is how a format the browser can name but not play is found
    /// out — the caller says so rather than opening a player that cannot start.
    @discardableResult
    func load(_ module: Module) -> Bool {
        pause()
        let opened = module.data.withUnsafeBufferPointer {
            cmod_open($0.baseAddress, Int32($0.count), Int32(Self.sampleRate))
        } == 1
        guard opened else {
            self.module = nil
            clearDetails()
            return false
        }
        self.module = module
        type = String(cString: cmod_type())
        tracker = String(cString: cmod_tracker())
        innerTitle = String(cString: cmod_title())
        channels = Int(cmod_channels())
        instruments = Int(cmod_instruments())
        samples = Int(cmod_samples())
        duration = cmod_duration()
        subsongs = Int(cmod_subsong_count())
        position = 0
        ended.pointee = false
        cmod_set_repeat(repeats ? 1 : 0)
        cmod_set_stereo_separation(Int32(stereoSeparation))
        return true
    }

    private func clearDetails() {
        type = ""; tracker = ""; innerTitle = ""
        channels = 0; instruments = 0; samples = 0
        duration = 0; subsongs = 0; position = 0
    }

    func play() {
        guard module != nil else { return }
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

    /// Silence, but stay where the module is: playing again picks up from here.
    func pause() {
        ticker?.invalidate(); ticker = nil
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    /// Silence and rewind to the top.
    func stop() {
        pause()
        apply { cmod_seek(0) }
        position = 0
        ended.pointee = false
    }

    /// Let go of the module altogether, so nothing is left loaded in the engine
    /// when the sheet closes.
    func unload() {
        pause()
        apply { cmod_close() }
        module = nil
        clearDetails()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        apply { cmod_seek(max(0, min(seconds, duration))) }
        position = cmod_position()
        ended.pointee = false
    }

    /// Modules with more than one song inside restart when another is picked,
    /// the same way choosing a SID subtune runs init again.
    func selectSubsong(_ index: Int) {
        guard index >= 0, index < subsongs else { return }
        apply {
            cmod_set_subsong(Int32(index))
            cmod_seek(0)
        }
        duration = cmod_duration()
        position = 0
        ended.pointee = false
    }

    /// Voice levels for the oscilloscope, as of the last buffer rendered.
    func voiceLevels() -> [Double] {
        (0..<Int(cmod_voice_count())).map { cmod_voice_level(Int32($0)) }
    }

    // MARK: - Plumbing

    /// Anything that touches the engine has to hold the render block out.
    private func apply(_ body: () -> Void) {
        os_unfair_lock_lock(lock)
        body()
        os_unfair_lock_unlock(lock)
    }

    /// One aligned word, written here and read by the render block without the
    /// lock: at worst it reads the old level for one buffer, and the ramp there
    /// covers even that.
    private func applyGain() {
        targetGain.pointee = Float(max(0, min(1, volume)))
    }

    /// The position display, and noticing that the module has run out. Four
    /// times a second is enough for a clock counting whole seconds and costs
    /// nothing next to the audio thread.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.position = cmod_position()
            if self.ended.pointee { self.stop() }
        }
    }

    private func attachSource() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)
        else { return }

        let lock = self.lock
        let scratch = self.scratch
        let capacity = self.scratchFrames
        let finished = self.ended
        let wanted = self.targetGain
        let reached = self.currentGain

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            guard os_unfair_lock_trylock(lock) else {
                for i in 0..<frames { left[i] = 0; right[i] = 0 }
                return noErr
            }
            let level = wanted.pointee
            var gain = reached.pointee
            let ramp = (level - gain) / Float(frames)
            var done = 0
            while done < frames {
                let chunk = min(capacity, frames - done)
                let got = Int(cmod_render(scratch, Int32(chunk)))
                if got < chunk { finished.pointee = true }
                // libopenmpt gives interleaved stereo; the node wants a plane
                // per channel.
                for i in 0..<chunk {
                    left[done + i] = Float(scratch[i * 2]) / 32768.0 * gain
                    right[done + i] = Float(scratch[i * 2 + 1]) / 32768.0 * gain
                    gain += ramp
                }
                done += chunk
            }
            reached.pointee = level
            os_unfair_lock_unlock(lock)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }
}
