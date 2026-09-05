import Foundation
import AVFoundation

/// Drives the vendored cSID engine from an audio render callback.
///
/// The engine is one global machine, so this is a single player: loading a
/// tune replaces whatever was playing.
final class SIDPlayer: ObservableObject {

    static let sampleRate = 44100.0

    @Published private(set) var isPlaying = false
    @Published private(set) var tune: SIDTune?
    @Published var errorMessage: String?

    /// Calls to the play routine per second. Zero keeps the tune's own timing.
    /// Applied where it stands, so the tune plays on.
    @Published var speedHz: Double = 0 { didSet { apply { csid_set_speed_hz(speedHz) } } }
    /// Written to A, X and Y before init — how a subtune is chosen. This one
    /// does restart: picking a song means running init again.
    @Published var selector: UInt8 = 0 { didSet { restart() } }
    /// Also applied mid-tune.
    @Published var sidModel: Int = 8580 { didSet { apply { csid_set_model(Int32(sidModel)) } } }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    /// Rendering happens on the audio thread while the UI reconfigures on the
    /// main one. The render block never blocks: if it cannot take the lock it
    /// emits silence for that buffer rather than stalling the audio thread.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Int16>
    /// Samples pushed to the output since the tune last started. Counted in the
    /// render block, so it measures what was actually heard and stops moving
    /// when playback does. A plain pointer keeps `self` out of that block.
    private let playedFrames: UnsafeMutablePointer<Int64>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        playedFrames = .allocate(capacity: 1)
        playedFrames.initialize(to: 0)
    }

    deinit {
        engine.stop()
        scratch.deallocate()
        playedFrames.deallocate()
        lock.deallocate()
    }

    // MARK: - Transport

    /// `preferredModel` is the remembered choice and takes precedence over the
    /// model a PSID header asks for.
    func load(_ tune: SIDTune, preferredModel: Int? = nil) {
        stop()
        self.tune = tune
        selector = tune.selector
        sidModel = preferredModel ?? tune.sidModel ?? 8580
        configure()
    }

    func play() {
        guard tune != nil else { return }
        if source == nil { attachSource() }
        do {
            if !engine.isRunning { try engine.start() }
            isPlaying = true
        } catch {
            errorMessage = "Could not start audio: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    func toggle() { isPlaying ? stop() : play() }

    /// Re-run init with the current settings, keeping playback going.
    private func restart() {
        guard tune != nil else { return }
        configure()
    }

    /// A small engine change made under the same lock the render block uses,
    /// so it cannot land halfway through a buffer.
    private func apply(_ change: () -> Void) {
        guard tune != nil else { return }
        os_unfair_lock_lock(lock)
        change()
        os_unfair_lock_unlock(lock)
    }

    fileprivate func configure() {
        guard let tune else { return }
        os_unfair_lock_lock(lock)
        playedFrames.pointee = 0
        cSID_init(Int32(Self.sampleRate))
        tune.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(tune.loadAddress))
        }
        csid_set_addresses(UInt32(tune.initAddress), UInt32(tune.playAddress))
        csid_set_sid(Int32(sidModel),
                     UInt32(tune.extraSIDAddresses.first ?? 0),
                     UInt32(tune.extraSIDAddresses.dropFirst().first ?? 0))
        csid_set_speed_hz(speedHz)
        csid_start(selector, selector)
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Oscilloscope

    var sidCount: Int { Int(csid_sid_count()) }

    /// How long the tune has been playing, from the tune's own start.
    var elapsed: TimeInterval { Double(playedFrames.pointee) / Self.sampleRate }

    func setScope(enabled: Bool) { csid_scope_enable(enabled ? 1 : 0) }

    /// A window of recent samples per track, for the tracks the given mode
    /// draws. Read without locking: a torn read costs at most one ragged frame,
    /// which is not worth stalling the audio thread for.
    func scopeSnapshot(mode: ScopeMode) -> [Int: [Int16]] {
        let length = Int(csid_scope_length())
        let (rows, columns) = ScopeRenderer.grid(mode: mode, sidCount: sidCount)
        var out: [Int: [Int16]] = [:]
        for row in 0..<rows {
            for column in 0..<columns {
                let track = ScopeRenderer.track(mode: mode, row: row, column: column)
                var buffer = [Int16](repeating: 0, count: length)
                buffer.withUnsafeMutableBufferPointer {
                    csid_scope_read(Int32(track), $0.baseAddress, Int32(length))
                }
                out[track] = buffer
            }
        }
        return out
    }

    /// Render `frames` samples without touching the audio graph, for the video
    /// export. The caller must not be playing at the time.
    func renderOffline(frames: Int, into buffer: inout [Int16]) {
        buffer.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, Int32(frames)) }
    }

    /// Re-arm the engine from scratch, used before an offline render.
    func prepareForOfflineRender() { configure() }

    // MARK: - Rendering

    private func attachSource() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        else { return }

        let lock = self.lock
        let scratch = self.scratch
        let capacity = self.scratchCapacity
        let played = self.playedFrames

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let frames = Int(frameCount)

            guard os_unfair_lock_trylock(lock) else {
                for i in 0..<frames { out[i] = 0 }
                return noErr
            }
            var done = 0
            while done < frames {
                let chunk = min(capacity, frames - done)
                csid_render(scratch, Int32(chunk))
                for i in 0..<chunk { out[done + i] = Float(scratch[i]) / 32768.0 }
                done += chunk
            }
            played.pointee += Int64(frames)
            os_unfair_lock_unlock(lock)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }
}
