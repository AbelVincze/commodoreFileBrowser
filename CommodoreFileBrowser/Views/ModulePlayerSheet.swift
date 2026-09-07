import SwiftUI
import AppKit

/// What the tracker sheet is showing. Held apart from the sheet itself so the
/// module can change while the sheet stays up, the same way `SIDRequest` is.
struct ModuleRequest: Identifiable {
    let id = UUID()
    /// The file name, which is the fallback when the module carries no title.
    var name: String
    var module: Module
    /// Folder an exported video goes to.
    var destination: URL?
}

/// The transport for a tracker module. Closing it stops playback and lets go
/// of the module, so nothing is left loaded in the engine.
///
/// Laid out like the SID sheet, and for the same reasons: the same transport
/// keys, the same oscilloscope and the same video export row. What it does not
/// have is the SID sheet's form — a module carries its whole song, so there is
/// nothing to fill in before it will play.
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
    @State private var showScope: Bool
    @State private var scopeMode: ModuleScopeMode
    @State private var exportSeconds: String
    @State private var exportResolution: VideoResolution
    @State private var exportAspect: VideoAspect
    @State private var exportProgress: Double?
    @State private var exportedTo: String?
    @State private var exportError: String?

    init(request: ModuleRequest, palette: Palette, player: ModulePlayer,
         settings: SettingsStore, onClose: @escaping () -> Void) {
        self.request = request
        self.palette = palette
        _player = ObservedObject(wrappedValue: player)
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
        _showScope = State(initialValue: settings.scopeEnabled)
        _scopeMode = State(initialValue: ModuleScopeMode(rawValue: settings.moduleScopeMode) ?? .mix)
        _exportSeconds = State(initialValue: String(Int(settings.exportSeconds)))
        _exportResolution = State(initialValue:
            VideoResolution(rawValue: settings.exportResolution) ?? .p720)
        _exportAspect = State(initialValue:
            VideoAspect(rawValue: settings.exportAspect) ?? .sixteenNine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            if player.isSeekable {
                progress
                Divider().overlay(palette.color(.border))
            }
            controls
            if showScope {
                Divider().overlay(palette.color(.border))
                ScopeView(player: player, mode: scopeMode, palette: palette)
                    .frame(height: scopeMode == .mix ? 90 : 180)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider().overlay(palette.color(.border))
                exportRow
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
            // Everything needed is already known, so start straight away.
            player.play()
        }
        .onChange(of: showScope) { _, on in
            player.setScope(enabled: on)
            settings.scopeEnabled = on
        }
        .onChange(of: scopeMode) { _, mode in settings.moduleScopeMode = mode.rawValue }
        .onChange(of: exportResolution) { _, value in settings.exportResolution = value.rawValue }
        .onChange(of: exportAspect) { _, value in settings.exportAspect = value.rawValue }
        .onDisappear { player.setScope(enabled: false); player.unload() }
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
                    // Reads the player rather than a copy of its own, so
                    // ⌘← and ⌘→ move the picker with them.
                    Picker("", selection: Binding(
                        get: { player.currentSubsong },
                        set: { player.selectSubsong($0) }
                    )) {
                        ForEach(0..<player.subsongs, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Spacer()
                }
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

                // libopenmpt's to give; a chiptune player routine takes no such
                // instruction.
                Toggle("Repeat", isOn: $player.repeats)
                    .foregroundStyle(palette.color(.text))
            }

            HStack(spacing: 8) {
                Toggle("Oscilloscope", isOn: $showScope)
                Spacer(minLength: 0)
                if showScope {
                    Picker("", selection: $scopeMode) {
                        ForEach(ModuleScopeMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if let exportError {
                Text(exportError)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.marked))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Export

    private var exportRow: some View {
        HStack(spacing: 8) {
            Text("Video").font(.system(size: 11)).frame(width: 42, alignment: .leading)
            Picker("", selection: $exportResolution) {
                ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            Picker("", selection: $exportAspect) {
                ForEach(VideoAspect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            TextField("30", text: $exportSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { rememberExportSeconds() }
            Text("seconds").font(.system(size: 10)).foregroundStyle(palette.color(.dim))
            Spacer(minLength: 0)
            if let exportProgress {
                ProgressView(value: exportProgress).frame(width: 90)
            } else {
                Button("Export…", action: exportVideo)
                    .buttonStyle(.bordered)
                    .disabled(request.destination == nil)
            }
        }
        .help("The export writes \(pictureSize)")
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if let exportedTo {
                Text(exportedTo)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(palette.color(.dim))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
            }
        }
    }

    private var pictureSize: String {
        let size = VideoFormat.size(exportResolution, exportAspect)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// A minute of 4K is a long wait, so the length is held to ten minutes.
    @discardableResult private func rememberExportSeconds() -> Double {
        let seconds = max(1, min(600, Double(exportSeconds) ?? settings.exportSeconds))
        exportSeconds = String(Int(seconds))
        settings.exportSeconds = seconds
        return seconds
    }

    private func exportVideo() {
        guard let folder = request.destination else { return }
        let seconds = rememberExportSeconds()
        let safeName = title.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safeName).mp4")

        var video = SIDVideoExporter.Settings()
        video.seconds = seconds
        video.size = VideoFormat.size(exportResolution, exportAspect)
        video.foreground = NSColor(palette.color(.text)).cgColor
        video.background = NSColor(palette.color(.panel)).cgColor
        video.grid = NSColor(palette.color(.border)).cgColor

        exportProgress = 0
        exportedTo = nil
        exportError = nil
        // The engine is ours alone for this, so the source is built here and
        // the module is left rewound and silent afterwards.
        let source = SIDVideoExporter.source(player: player, mode: scopeMode)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SIDVideoExporter.export(source: source, settings: video, to: url) {
                    exportProgress = $0
                }
                DispatchQueue.main.async {
                    exportProgress = nil
                    exportedTo = url.path
                }
            } catch {
                DispatchQueue.main.async {
                    exportProgress = nil
                    exportError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 8) {
            // Left at the regular size while the rest of the sheet is small.
            // These are what the sheet is for; everything above them is setup.
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

                // Held rather than clicked, so the gesture rather than the
                // action is what drives it.
                Button(action: {}) {
                    Image(systemName: "forward.fill").frame(width: 18)
                }
                .disabled(!player.isPlaying || !player.canFastForward)
                .help(player.canFastForward
                      ? "Hold to play at four times speed"
                      : "This player has no tempo to change")
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in player.setFastForward(true) }
                    .onEnded { _ in player.setFastForward(false) })
            }
            .controlSize(.regular)

            if player.isFastForwarding {
                Text("×4")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.marked))
                    .fixedSize()
            }

            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.color(.dim))
                // Written to the settings when the drag ends rather than on
                // every step of it, which would re-encode the whole store a
                // hundred times over one sweep of the slider.
                Slider(value: $player.volume, in: 0...1) { editing in
                    if !editing { settings.sidVolume = player.volume }
                }
                .frame(width: 80)
            }
            .help("Volume. Fast forward plays at half of it.")

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
