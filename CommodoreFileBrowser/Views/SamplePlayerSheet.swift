import SwiftUI
import AppKit

/// What the sample sheet is showing, held apart from the sheet itself so the
/// sample can change while the sheet stays up — the same as `ModuleRequest`.
struct SampleRequest: Identifiable {
    let id = UUID()
    /// The file name, which is the fallback when the sample carries no NAME.
    var name: String
    var sound: SampledSound
}

/// The transport for an 8SVX sample. Closing it stops playback and lets go of
/// the sound.
///
/// The tracker sheet without the tracker: the same transport keys, the same
/// oscilloscope, and none of the things only a module has — no subsongs, no
/// engine to choose, no pattern to be somewhere in. It has no video export
/// either, and that is not an oversight: the exporter counts its video frames
/// in SID samples per second, and a sample at 16726 Hz would come out of step
/// with its own picture.
struct SamplePlayerSheet: View {
    let request: SampleRequest
    let palette: Palette
    @ObservedObject var player: SamplePlayer
    @ObservedObject var settings: SettingsStore
    let onClose: () -> Void

    /// Where the slider sits while it is being dragged, so the thumb does not
    /// jump back under the finger before the player catches up.
    @State private var scrubbing: Double?
    @State private var showScope: Bool

    init(request: SampleRequest, palette: Palette, player: SamplePlayer,
         settings: SettingsStore, onClose: @escaping () -> Void) {
        self.request = request
        self.palette = palette
        _player = ObservedObject(wrappedValue: player)
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
        _showScope = State(initialValue: settings.scopeEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            progress
            Divider().overlay(palette.color(.border))
            controls
            if showScope {
                Divider().overlay(palette.color(.border))
                ScopeView(palette: palette,
                          isRunning: player.isPlaying,
                          columns: 1,
                          lineWidth: 1.5,
                          traces: { player.scopeSnapshot() },
                          mode: "mono")
                    .frame(height: 90)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            Divider().overlay(palette.color(.border))
            transport
        }
        .frame(width: showScope ? 560 : 460)
        .controlSize(.small)
        .background(palette.color(.window))
        .onAppear {
            player.setScope(enabled: showScope)
            player.volume = settings.sidVolume
            if player.owner != request.id { player.load(request.sound, owner: request.id) }
            player.play()
        }
        .onChange(of: showScope) { _, on in
            player.setScope(enabled: on)
            settings.scopeEnabled = on
        }
        .onDisappear {
            // Only when this sheet's sample is still the one loaded. Stepping
            // to the next file loads its sound before this sheet goes away, and
            // unloading here would take it straight back out.
            guard player.owner == request.id else { return }
            player.setScope(enabled: false)
            player.unload()
        }
    }

    // MARK: - Header

    private var title: String {
        let inner = (request.sound.name ?? "").trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? request.name : inner
    }

    private var subtitle: String {
        var parts = ["IFF 8SVX"]
        parts.append("\(Int(request.sound.sampleRate)) Hz")
        parts.append("\(request.sound.frames.count.formatted(.number)) samples")
        if request.sound.loop != nil { parts.append("looping") }
        if request.sound.octaves > 1 { parts.append("\(request.sound.octaves) octaves, first shown") }
        if let note = request.sound.annotation { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.color(.dim))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Position

    /// A sample is seconds long rather than minutes, so the clock counts
    /// tenths where a module's counts whole seconds.
    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--.-" }
        return seconds >= 60
            ? String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
            : String(format: "%.1fs", seconds)
    }

    private var progress: some View {
        HStack(spacing: 10) {
            Text(clock(scrubbing ?? player.position))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.color(.text))
                .frame(width: 52, alignment: .leading)

            Slider(value: Binding(
                get: { scrubbing ?? min(player.position, max(player.duration, 0.001)) },
                set: { scrubbing = $0 }
            ), in: 0...max(player.duration, 0.001)) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            .disabled(player.duration <= 0)

            Text(clock(player.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.color(.dim))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // An instrument carries a loop point; an effect does not, and
            // there is nothing to turn on for it.
            if request.sound.loop != nil {
                Toggle("Repeat the loop", isOn: $player.looping)
                    .foregroundStyle(palette.color(.text))
                    .help("The attack plays once and the tail runs round, "
                          + "which is how the sample was meant to be held")
            }
            Toggle("Oscilloscope", isOn: $showScope)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")

                Button { player.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 18)
                }
                .help("Stop and rewind to the beginning")
            }
            .controlSize(.regular)

            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.color(.dim))
                Slider(value: $player.volume, in: 0...1) { editing in
                    if !editing { settings.sidVolume = player.volume }
                }
                .frame(width: 80)
            }

            if let error = player.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.marked))
                    .lineLimit(1)
            }
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }
}
