import Foundation
import AVFoundation

/// What the module oscilloscope draws. There is no per-voice equivalent of the
/// SID's: libopenmpt reports a level per channel but not the samples behind it,
/// and c-flod reports nothing at all, so what is drawn is the output — which is
/// also the one thing both engines have.
enum ModuleScopeMode: String, CaseIterable, Identifiable {
    case mix, stereo
    var id: String { rawValue }
    var label: String { self == .mix ? "Mixed" : "Left / right" }
    var traceCount: Int { self == .mix ? 1 : 2 }
}

/// Drives the vendored module engines from an audio render callback.
///
/// Shaped like `SIDPlayer` next door, and for the same reason: the engines are
/// global machines, so loading a module replaces whatever was playing. What
/// differs is that a module is stereo, knows how long it runs and can be seeked
/// — a tracker file carries its whole song rather than a routine to call.
///
/// There are two engines behind this. libopenmpt is asked first and plays the
/// tracker formats; c-flod is asked second and plays the Amiga chiptune
/// formats, where the file is a player routine with its data rather than a
/// pattern table. Which one has it changes what can be said about the module:
/// c-flod knows neither how long a tune runs nor where it has got to, so the
/// sheet shows no clock for those and cannot seek them, and its pattern rate
/// cannot be changed so there is no fast forward either.
final class ModulePlayer: ObservableObject {

    static let sampleRate = 44100.0

    /// Held down, the module is stepped through its patterns four times as fast
    /// while the samples still come out at the render rate: speed without a
    /// change of pitch. Only libopenmpt can be told this, and four is its
    /// ceiling — it throws above that rather than clamping, so asking for the
    /// SID player's ten would apply nothing at all.
    static let fastForwardFactor = 4.0
    /// Four times the pattern rate at full level is harsh, so it plays at half
    /// while the key is held. The slider does not move for it.
    static let fastForwardGain: Float = 0.5

    /// Which engine has the module.
    enum Engine { case openMPT, cflod }

    @Published private(set) var isPlaying = false
    @Published private(set) var module: Module?
    @Published private(set) var engine_: Engine = .openMPT
    @Published private(set) var isFastForwarding = false
    /// A tune whose pattern rate cannot be changed cannot be fast forwarded.
    var canFastForward: Bool { engine_ == .openMPT && cmod_can_set_tempo() == 1 }
    /// Whether the position and the length are known. c-flod reports neither.
    var isSeekable: Bool { engine_ == .openMPT && duration > 0 }

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
    /// Which song inside the module is playing, so the arrows can step it and
    /// the sheet's picker follows when they do.
    @Published private(set) var currentSubsong = 0

    /// Where playback has got to, in seconds. Read from the engine on the main
    /// thread rather than counted in the render block: libopenmpt keeps the
    /// position itself, and it moves with seeks and pattern jumps.
    @Published private(set) var position: Double = 0

    /// Output level, 0 to 1.
    @Published var volume: Double = 1 { didSet { applyGain() } }
    /// Start again at the end rather than stopping.
    /// Only libopenmpt can be told this; a c-flod tune stops when it stops.
    @Published var repeats = false {
        didSet { apply { if engine_ == .openMPT { cmod_set_repeat(repeats ? 1 : 0) } } }
    }
    /// 100 is the stereo the file asks for, 0 is mono. Amiga modules pan hard
    /// left and right by design, which is tiring on headphones.
    @Published var stereoSeparation: Double = 100 {
        didSet { apply { if engine_ == .openMPT { cmod_set_stereo_separation(Int32(stereoSeparation)) } } }
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
    /// Read by the render block to pick an engine, so it never touches Swift
    /// state from the audio thread.
    private let onCflod: UnsafeMutablePointer<Bool>
    private let targetGain: UnsafeMutablePointer<Float>
    private let currentGain: UnsafeMutablePointer<Float>

    /// The oscilloscope tap. The SID engine keeps its own ring inside the C,
    /// per voice; here there is nothing to tap but the output, so the ring is
    /// filled in the render block from what was just handed to the speakers.
    /// Two channels of it, written as plain pointers so the audio thread never
    /// touches Swift state.
    static let scopeLength = 2048
    private let scopeRing: UnsafeMutablePointer<Int16>      // interleaved, as rendered
    private let scopePosition: UnsafeMutablePointer<Int>
    private let scopeOn: UnsafeMutablePointer<Bool>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
        ended = .allocate(capacity: 1)
        ended.initialize(to: false)
        onCflod = .allocate(capacity: 1)
        onCflod.initialize(to: false)
        targetGain = .allocate(capacity: 1)
        targetGain.initialize(to: 1)
        currentGain = .allocate(capacity: 1)
        currentGain.initialize(to: 1)
        scopeRing = .allocate(capacity: Self.scopeLength * 2)
        scopeRing.initialize(repeating: 0, count: Self.scopeLength * 2)
        scopePosition = .allocate(capacity: 1)
        scopePosition.initialize(to: 0)
        scopeOn = .allocate(capacity: 1)
        scopeOn.initialize(to: false)
    }

    deinit {
        ticker?.invalidate()
        engine.stop()
        scratch.deallocate()
        ended.deallocate()
        onCflod.deallocate()
        targetGain.deallocate()
        currentGain.deallocate()
        scopeRing.deallocate()
        scopePosition.deallocate()
        scopeOn.deallocate()
        lock.deallocate()
    }

    // MARK: - Transport

    /// Hand a module to the engine. Returns false when libopenmpt will not have
    /// it, which is how a format the browser can name but not play is found
    /// out — the caller says so rather than opening a player that cannot start.
    @discardableResult
    func load(_ module: Module) -> Bool {
        pause()
        cmod_close()
        cflod_close()

        // libopenmpt first: it plays the tracker formats, and it is the one
        // that can say how long a module runs.
        let byOpenMPT = module.data.withUnsafeBufferPointer {
            cmod_open($0.baseAddress, Int32($0.count), Int32(Self.sampleRate))
        } == 1
        if byOpenMPT {
            engine_ = .openMPT
            onCflod.pointee = false
            self.module = module
            type = String(cString: cmod_type())
            tracker = String(cString: cmod_tracker())
            innerTitle = String(cString: cmod_title())
            channels = Int(cmod_channels())
            instruments = Int(cmod_instruments())
            samples = Int(cmod_samples())
            duration = cmod_duration()
            subsongs = Int(cmod_subsong_count())
            currentSubsong = 0
            position = 0
            ended.pointee = false
            cmod_set_repeat(repeats ? 1 : 0)
            cmod_set_stereo_separation(Int32(stereoSeparation))
            return true
        }

        // Then c-flod, for the Amiga chiptune players. It answers far fewer
        // questions about what it opened: a player routine does not carry a
        // title, a length, or a count of anything.
        let byCflod = module.data.withUnsafeBufferPointer {
            cflod_open($0.baseAddress, Int32($0.count))
        } == 1
        guard byCflod else {
            self.module = nil
            clearDetails()
            return false
        }
        engine_ = .cflod
        onCflod.pointee = true
        self.module = module
        type = ""
        tracker = String(cString: cflod_player_name())
        innerTitle = ""
        channels = 4                    // the Amiga's four voices
        instruments = 0; samples = 0
        duration = 0                    // unknown, so the sheet shows no clock
        subsongs = Int(cflod_subsong_count())
        currentSubsong = 0
        position = 0
        ended.pointee = false
        return true
    }

    private func clearDetails() {
        type = ""; tracker = ""; innerTitle = ""
        channels = 0; instruments = 0; samples = 0
        duration = 0; subsongs = 0; currentSubsong = 0; position = 0
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
        setFastForward(false)
        ticker?.invalidate(); ticker = nil
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    /// Silence and rewind to the top. c-flod cannot seek, so starting it again
    /// means running the player's own init — the same thing selecting a song
    /// does.
    func stop() {
        pause()
        apply {
            if engine_ == .openMPT { cmod_seek(0) } else { cflod_set_subsong(0) }
        }
        position = 0
        ended.pointee = false
    }

    /// Let go of the module altogether, so nothing is left loaded in the engine
    /// when the sheet closes.
    func unload() {
        pause()
        apply { cmod_close(); cflod_close() }
        module = nil
        clearDetails()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Fast forward, for as long as the key is held.
    ///
    /// libopenmpt's own tempo factor rather than anything of ours: the module
    /// is stepped through its patterns ten times as fast while the samples
    /// still come out at the render rate, so it races without changing pitch,
    /// and the position it reports races with it. A c-flod tune has no such
    /// control, so it is not offered one.
    func setFastForward(_ on: Bool) {
        guard on != isFastForwarding, module != nil, canFastForward else { return }

        isFastForwarding = on
        apply { cmod_set_tempo_factor(on ? Self.fastForwardFactor : 1) }
        applyGain()
    }

    func seek(to seconds: Double) {
        guard engine_ == .openMPT else { return }
        apply { cmod_seek(max(0, min(seconds, duration))) }
        position = cmod_position()
        ended.pointee = false
    }

    /// Modules with more than one song inside restart when another is picked,
    /// the same way choosing a SID subtune runs init again.
    func selectSubsong(_ index: Int) {
        guard index >= 0, index < subsongs else { return }
        currentSubsong = index
        apply {
            if engine_ == .openMPT {
                cmod_set_subsong(Int32(index))
                cmod_seek(0)
            } else {
                cflod_set_subsong(Int32(index))
            }
        }
        duration = engine_ == .openMPT ? cmod_duration() : 0
        position = 0
        ended.pointee = false
    }

    /// Voice levels for the oscilloscope, as of the last buffer rendered.
    /// c-flod keeps none, so those modules have nothing to show.
    func voiceLevels() -> [Double] {
        guard engine_ == .openMPT else { return [] }
        return (0..<Int(cmod_voice_count())).map { cmod_voice_level(Int32($0)) }
    }

    // MARK: - Oscilloscope

    /// Capture costs a copy per buffer, so it is only on while something is
    /// drawing it.
    func setScope(enabled: Bool) {
        scopeOn.pointee = enabled
        guard enabled else { return }
        scopeRing.update(repeating: 0, count: Self.scopeLength * 2)
        scopePosition.pointee = 0
    }

    /// The traces the scope draws, oldest sample first. Read without the lock:
    /// a torn read costs one ragged frame, which is not worth stalling the
    /// audio thread for — the same trade the SID player makes.
    func scopeSnapshot(mode: ModuleScopeMode) -> [[Int16]] {
        let length = Self.scopeLength
        var left = [Int16](repeating: 0, count: length)
        var right = [Int16](repeating: 0, count: length)
        var p = scopePosition.pointee % length
        for i in 0..<length {
            left[i] = scopeRing[p * 2]
            right[i] = scopeRing[p * 2 + 1]
            p = (p + 1) % length
        }
        guard mode == .mix else { return [left, right] }
        // Halved before summing, so a mix cannot clip where neither side does.
        var mixed = [Int16](repeating: 0, count: length)
        for i in 0..<length {
            mixed[i] = Int16(Int(left[i]) / 2 + Int(right[i]) / 2)
        }
        return [mixed]
    }

    // MARK: - Rendering for the video export

    /// Rewind to the top without touching the audio graph.
    func prepareForOfflineRender() {
        apply {
            if engine_ == .openMPT { cmod_set_tempo_factor(1); cmod_seek(0) }
            else { cflod_set_subsong(0) }
        }
        position = 0
        ended.pointee = false
    }

    /// Render `frames` of interleaved stereo straight from the engine, feeding
    /// the scope as the audio thread would. The caller must not be playing.
    func renderOffline(frames: Int, into buffer: inout [Int16]) {
        buffer.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            _ = engine_ == .cflod ? cflod_render(base, Int32(frames))
                                  : cmod_render(base, Int32(frames))
            Self.capture(base, frames: frames,
                         ring: scopeRing, position: scopePosition, on: scopeOn)
        }
    }

    /// Copy a rendered buffer into the scope ring. Static and pointer-only so
    /// the render block can call it without touching `self`.
    private static func capture(_ samples: UnsafePointer<Int16>, frames: Int,
                                ring: UnsafeMutablePointer<Int16>,
                                position: UnsafeMutablePointer<Int>,
                                on: UnsafeMutablePointer<Bool>) {
        guard on.pointee else { return }
        var p = position.pointee
        for i in 0..<frames {
            ring[(p % scopeLength) * 2] = samples[i * 2]
            ring[(p % scopeLength) * 2 + 1] = samples[i * 2 + 1]
            p += 1
        }
        position.pointee = p % scopeLength
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
        let asked = Float(max(0, min(1, volume)))
        targetGain.pointee = isFastForwarding ? asked * Self.fastForwardGain : asked
    }

    /// The position display, and noticing that the module has run out. Four
    /// times a second is enough for a clock counting whole seconds and costs
    /// nothing next to the audio thread.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // c-flod does not report a position, so the clock stays at zero and
            // only the end-of-tune check matters there.
            if self.engine_ == .openMPT { self.position = cmod_position() }
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
        let cflod = self.onCflod
        let wanted = self.targetGain
        let reached = self.currentGain
        let ring = self.scopeRing
        let ringPosition = self.scopePosition
        let capturing = self.scopeOn

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
                let got = Int(cflod.pointee ? cflod_render(scratch, Int32(chunk))
                                            : cmod_render(scratch, Int32(chunk)))
                if got < chunk { finished.pointee = true }
                // Before the gain, so the trace shows the module rather than
                // how loud it is being played.
                ModulePlayer.capture(scratch, frames: chunk,
                                     ring: ring, position: ringPosition, on: capturing)
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
