import SwiftUI
import AppKit

/// What the browser hands the player: the file, and whether its addresses were
/// worked out or have to be typed in.
struct SIDRequest: Identifiable {
    let id = UUID()
    var name: String
    var data: [UInt8]
    /// Nil when nothing could be detected, or when detection was skipped.
    var detected: SIDTune?
    /// Folder an exported video goes to.
    var destination: URL?
}

/// The load form and the transport in one sheet. Closing it stops playback.
struct SIDPlayerSheet: View {
    let request: SIDRequest
    let palette: Palette
    @ObservedObject var player: SIDPlayer
    @ObservedObject var settings: SettingsStore
    let onClose: () -> Void

    @State private var initText: String
    @State private var playText: String
    @State private var speedText: String
    @State private var loadError: String?
    @State private var showScope: Bool
    @State private var scopeMode: ScopeMode
    @State private var exportSeconds: String
    @State private var exportResolution: VideoResolution
    @State private var exportAspect: VideoAspect
    @State private var exportProgress: Double?
    @State private var exportedTo: String?
    @State private var elapsed: TimeInterval = 0
    @State private var rateHz: Double = 0
    /// The addresses the engine was last built from, so play knows whether it
    /// is resuming or has to build a tune from edited fields first.
    @State private var loadedFrom = ""
    /// .common so the readout keeps counting while a menu or a drag is up.
    @State private var clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private static let speedPresets: [Double] = [0, 50, 100, 200, 400]

    init(request: SIDRequest, palette: Palette, player: SIDPlayer,
         settings: SettingsStore, onClose: @escaping () -> Void) {
        self.request = request
        self.palette = palette
        _player = ObservedObject(wrappedValue: player)
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
        _showScope = State(initialValue: settings.scopeEnabled)
        _scopeMode = State(initialValue: ScopeMode(rawValue: settings.scopeMode) ?? .voices)
        // With nothing detected, guess the usual jump table: init sits at the
        // load address and play three bytes on. The load address is the first
        // two bytes of the PRG.
        let load = request.data.count > 2
            ? Int(request.data[0]) | Int(request.data[1]) << 8
            : 0x1000
        _initText = State(initialValue: String(format: "%04X", request.detected?.initAddress ?? load))
        _playText = State(initialValue: String(format: "%04X",
                                               request.detected?.playAddress ?? ((load + 3) & 0xFFFF)))
        // A new file always starts on the tune's own timing: a rate that suited
        // the last tune says nothing about this one.
        _speedText = State(initialValue: "")
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
            form
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
        // Set once for the sheet rather than per control: the buttons, pickers,
        // steppers and toggles in it all read at one size that way.
        .controlSize(.small)
        .background(palette.color(.window))
        .onAppear {
            player.setScope(enabled: showScope)
            player.volume = settings.sidVolume
            player.speedHz = 0
            loadTune()
            // Everything needed is already known, so start straight away.
            if request.detected != nil { player.play() }
        }
        .onChange(of: showScope) { _, on in
            player.setScope(enabled: on)
            settings.scopeEnabled = on
        }
        .onChange(of: scopeMode) { _, mode in settings.scopeMode = mode.rawValue }
        .onChange(of: player.sidModel) { _, model in settings.sidModel = model }
        .onChange(of: exportResolution) { _, value in settings.exportResolution = value.rawValue }
        .onChange(of: exportAspect) { _, value in settings.exportAspect = value.rawValue }
        .onReceive(clock) { _ in
            elapsed = player.elapsed
            rateHz = player.playRateHz
            // Fast forward lasts as long as the mouse is down. If the release
            // was missed — let go outside the window, or swallowed on its way
            // to the key — this is what ends it, rather than the tune being
            // left racing.
            if player.isFastForwarding, NSEvent.pressedMouseButtons & 1 == 0 {
                player.setFastForward(false)
            }
        }
        .onDisappear { player.setScope(enabled: false); player.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.detected?.title ?? request.name)
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

    private var subtitle: String {
        var parts: [String] = []
        if let tune = request.detected {
            parts.append("from the \(tune.source.rawValue)")
            if let author = tune.author { parts.append(author) }
            switch tune.songCount {
            case nil: parts.append("multiple songs")
            case let count? where count > 1: parts.append("\(count) songs")
            default: break
            }
            parts.append(contentsOf: extent(load: tune.loadAddress, bytes: tune.payload.count))
        } else {
            // Kept short: the extent that follows is the useful part, and the
            // line truncates to one line.
            parts.append("addresses not detected")
            // A PRG carries its load address in its first two bytes. Where the
            // code sits and how far it runs are the clues for guessing init and
            // play, so they are worth showing even when nothing else is known.
            if request.data.count > 2 {
                let load = Int(request.data[0]) | Int(request.data[1]) << 8
                parts.append(contentsOf: extent(load: load, bytes: request.data.count - 2,
                                                includingEnd: true))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func extent(load: Int, bytes: Int, includingEnd: Bool = false) -> [String] {
        var out = [String(format: "load $%04X", load), String(format: "$%04X bytes", bytes)]
        if includingEnd { out.append(String(format: "ends $%04X", (load + bytes - 1) & 0xFFFF)) }
        return out
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                field("Init", text: $initText)
                field("Play", text: $playText)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("Song").font(.system(size: 11)).frame(width: 42, alignment: .leading)
                Stepper(value: Binding(get: { Int(player.selector) },
                                       set: { player.selector = UInt8(max(0, min(255, $0))) }),
                        in: 0...255) {
                    Text("A,X,Y = \(player.selector)")
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize()
                }
                .fixedSize()
                Spacer(minLength: 0)
                Picker("", selection: $player.sidModel) {
                    Text("8580").tag(8580)
                    Text("6581").tag(6581)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }

            HStack(spacing: 8) {
                Text("Speed").font(.system(size: 11)).frame(width: 42, alignment: .leading)
                Picker("", selection: Binding(
                    get: { Self.speedPresets.contains(player.speedHz) ? player.speedHz : -1 },
                    set: {
                        guard $0 >= 0 else { return }          // "Other": the field speaks
                        player.speedHz = $0
                        // Nothing to show for the tune's own timing, which is a
                        // rate the tune states rather than one to type.
                        speedText = $0 > 0 ? String(Int($0)) : ""
                    }
                )) {
                    Text("Tune").tag(0.0)
                    Text("50").tag(50.0)
                    Text("100").tag(100.0)
                    Text("200").tag(200.0)
                    Text("400").tag(400.0)
                    Text("Other").tag(-1.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("", text: $speedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(applyTypedSpeed)
                Text("Hz").font(.system(size: 10)).foregroundStyle(palette.color(.dim))
            }

            HStack(spacing: 8) {
                Toggle("Oscilloscope", isOn: $showScope).font(.system(size: 11))
                Spacer(minLength: 0)
                if showScope {
                    Picker("", selection: $scopeMode) {
                        ForEach(ScopeMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.marked))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 42, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit(loadTune)
        }
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

    /// What the export will write, so the choice above is visible as pixels.
    private var pictureSize: String {
        let size = VideoFormat.size(exportResolution, exportAspect)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// Blank means the tune's own timing, the same as picking Tune.
    private func applyTypedSpeed() {
        let text = speedText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { player.speedHz = 0; return }
        if let hz = Double(text), hz >= 0, hz <= 20000 {
            player.speedHz = hz
            if hz == 0 { speedText = "" }
        }
    }

    /// A minute of 4K is a long wait, so the length is held to ten minutes.
    @discardableResult private func rememberExportSeconds() -> Double {
        let seconds = max(1, min(600, Double(exportSeconds) ?? settings.exportSeconds))
        exportSeconds = String(Int(seconds))
        settings.exportSeconds = seconds
        return seconds
    }

    private func exportVideo() {
        guard let folder = request.destination, let tune = player.tune else { return }
        let seconds = rememberExportSeconds()
        let safeName = (request.detected?.title ?? request.name)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safeName).mp4")

        // Named apart from the settings store, which this function also writes.
        var video = SIDVideoExporter.Settings()
        video.seconds = seconds
        video.size = VideoFormat.size(exportResolution, exportAspect)
        video.foreground = NSColor(palette.color(.text)).cgColor
        video.background = NSColor(palette.color(.panel)).cgColor
        video.grid = NSColor(palette.color(.border)).cgColor

        exportProgress = 0
        exportedTo = nil
        let player = self.player
        let mode = scopeMode
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let source = SIDVideoExporter.source(tune: tune, player: player, mode: mode)
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
                    loadError = error.localizedDescription
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
                Button(action: playPause) {
                    glyph(player.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .help(player.isPlaying ? "Pause" : "Play")

                Button(action: stopPlayback) {
                    glyph("stop.fill")
                }
                .help("Stop and rewind to the beginning")

                // Held rather than clicked, so the gesture rather than the
                // action is what drives it: the tune runs ten times as fast for
                // exactly as long as the mouse is down, wherever it is let go.
                Button(action: {}) {
                    glyph("forward.fill")
                }
                .disabled(!player.isPlaying)
                .help("Hold to play at ten times speed")
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in player.setFastForward(true) }
                    .onEnded { _ in player.setFastForward(false) })
            }
            .controlSize(.regular)

            Text(playTime)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(player.isPlaying ? palette.color(.text) : palette.color(.dim))
                .fixedSize()
            Text(rateLabel)
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .fixedSize()

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

            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    /// One box for every transport glyph. The symbols are not all the same
    /// height — play stands a point taller than pause — so leaving the height
    /// to the symbol made the row change size as the button changed, and the
    /// centred sheet shift half a point under it.
    private func glyph(_ name: String) -> some View {
        Image(systemName: name).frame(width: 18, height: 12)
    }

    private var playTime: String {
        let tenths = max(0, Int((elapsed * 10).rounded(.down)))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    /// The rate the play routine is actually being called at, which is the one
    /// place the tune's own timing shows as a figure.
    private var rateLabel: String {
        guard rateHz > 0 else { return "" }
        return String(format: "%.0f Hz", rateHz) + (player.isFastForwarding ? " ×10" : "")
    }

    /// Resume where the sound stopped, unless the addresses have been edited
    /// since — then build the tune again and start it from the top.
    private func playPause() {
        if player.isPlaying { player.pause(); return }
        if player.tune == nil || loadedFrom != fieldSignature { loadTune() }
        player.play()
    }

    private func stopPlayback() {
        player.stop()
        elapsed = 0
    }

    private var fieldSignature: String { "\(initText)/\(playText)" }

    /// Build a tune from whatever the fields currently say and hand it over.
    private func loadTune() {
        guard let initAddress = Int(initText.trimmingCharacters(in: .whitespaces), radix: 16),
              let playAddress = Int(playText.trimmingCharacters(in: .whitespaces), radix: 16)
        else { loadError = "Init and play must be four hex digits."; return }
        loadError = nil

        var tune = request.detected
        if tune != nil {
            tune!.initAddress = initAddress
            tune!.playAddress = playAddress
        } else {
            tune = SIDTuneLoader.raw(request.data, name: request.name,
                                     initAddress: initAddress, playAddress: playAddress)
        }
        guard let tune else { loadError = "The file is too short to be a tune."; return }
        player.load(tune, preferredModel: settings.sidModel)
        loadedFrom = fieldSignature
    }
}
