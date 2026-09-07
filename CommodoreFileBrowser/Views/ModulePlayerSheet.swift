import SwiftUI

/// What the tracker sheet is showing. Held apart from the sheet itself so the
/// module can change while the sheet stays up, the same way `SIDRequest` is.
struct ModuleRequest: Identifiable {
    let id = UUID()
    /// The file name, which is the fallback when the module carries no title.
    var name: String
    var module: Module
}

/// The transport for a tracker module. Closing it stops playback and lets go
/// of the module, so nothing is left loaded in the engine.
///
/// Shorter than the SID sheet on purpose: there is nothing to fill in. A SID
/// file may need two addresses typed in before it will play at all, while a
/// module carries its whole song, so the sheet opens playing.
struct ModulePlayerSheet: View {
    let request: ModuleRequest
    let palette: Palette
    @ObservedObject var player: ModulePlayer
    @ObservedObject var settings: SettingsStore
    let onClose: () -> Void

    /// Where the slider sits while it is being dragged. The player keeps
    /// reporting the old position until the drag ends, so the thumb would jump
    /// back under the finger without this.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            if player.isSeekable {
                progress
                Divider().overlay(palette.color(.border))
            }
            controls
            Divider().overlay(palette.color(.border))
            transport
        }
        .frame(width: 460)
        .controlSize(.small)
        .background(palette.color(.window))
        .onAppear {
            player.volume = settings.sidVolume
            // Everything needed is already known, so start straight away.
            player.play()
        }
        .onDisappear { player.unload() }
    }

    // MARK: - Header

    private var title: String {
        let inner = player.innerTitle.trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? request.name : inner
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

    /// What the file is, said once. The format comes from the browser's own
    /// reading of the bytes; the tracker name and the counts come from the
    /// engine, and any of them may be missing.
    private var subtitle: String {
        var parts = [request.module.format.name]
        let tracker = player.tracker.trimmingCharacters(in: .whitespaces)
        if !tracker.isEmpty, tracker != request.module.format.name { parts.append(tracker) }
        if player.channels > 0 { parts.append("\(player.channels) channels") }
        if player.instruments > 0 { parts.append("\(player.instruments) instruments") }
        else if player.samples > 0 { parts.append("\(player.samples) samples") }
        if player.subsongs > 1 { parts.append("\(player.subsongs) songs") }
        parts.append(sizeText)
        return parts.joined(separator: " · ")
    }

    private var sizeText: String {
        let kb = Double(request.module.data.count) / 1024
        return kb >= 1024 ? String(format: "%.1f MB", kb / 1024) : String(format: "%.0f KB", kb)
    }

    // MARK: - Position

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private var progress: some View {
        HStack(spacing: 10) {
            Text(clock(scrubbing ?? player.position))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.color(.text))
                .frame(width: 44, alignment: .leading)

            // A module whose length libopenmpt could not work out gets a bar
            // that does not move rather than one that lies.
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
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if player.subsongs > 1 {
                HStack(spacing: 8) {
                    Text("Song").frame(width: 78, alignment: .leading)
                        .foregroundStyle(palette.color(.dim))
                    Picker("", selection: Binding(
                        get: { currentSubsong },
                        set: { player.selectSubsong($0); currentSubsong = $0 }
                    )) {
                        ForEach(0..<player.subsongs, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text("Volume").frame(width: 78, alignment: .leading)
                    .foregroundStyle(palette.color(.dim))
                Slider(value: $player.volume, in: 0...1)
                    .onChange(of: player.volume) { _, value in settings.sidVolume = value }
            }

            // Amiga modules pan the voices hard left and right, which is how
            // they were meant to sound on speakers and tiring on headphones.
            if player.engine_ == .openMPT {
                HStack(spacing: 8) {
                    Text("Stereo").frame(width: 78, alignment: .leading)
                        .foregroundStyle(palette.color(.dim))
                    Slider(value: $player.stereoSeparation, in: 0...100)
                    Text("\(Int(player.stereoSeparation))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.color(.dim))
                        .frame(width: 34, alignment: .trailing)
                }
            }

            // Both of these are libopenmpt's to give; a chiptune player routine
            // takes no such instruction.
            if player.engine_ == .openMPT {
                Toggle("Repeat", isOn: $player.repeats)
                    .foregroundStyle(palette.color(.text))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @State private var currentSubsong = 0

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 8) {
            Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Stop") { player.stop() }
            Spacer()
            if let error = player.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }
}
