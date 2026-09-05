import SwiftUI

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
    @State private var exportSeconds = "30"
    @State private var exportProgress: Double?
    @State private var exportedTo: String?

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
        _speedText = State(initialValue: "0")
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
        .background(palette.color(.window))
        .onAppear {
            player.setScope(enabled: showScope)
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
            if tune.songCount > 1 { parts.append("\(tune.songCount) songs") }
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
                    set: { if $0 >= 0 { player.speedHz = $0; speedText = String(Int($0)) } }
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
                TextField("Hz", text: $speedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        if let hz = Double(speedText), hz >= 0, hz <= 20000 { player.speedHz = hz }
                    }
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
            TextField("30", text: $exportSeconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
                .font(.system(size: 11, design: .monospaced))
            Text("seconds").font(.system(size: 10)).foregroundStyle(palette.color(.dim))
            Spacer(minLength: 0)
            if let exportProgress {
                ProgressView(value: exportProgress).frame(width: 90)
            } else {
                Button("Export…", action: exportVideo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(request.destination == nil)
            }
        }
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

    private func exportVideo() {
        guard let folder = request.destination, let tune = player.tune else { return }
        let seconds = max(1, min(600, Double(exportSeconds) ?? 30))
        let safeName = (request.detected?.title ?? request.name)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safeName).mp4")

        var settings = SIDVideoExporter.Settings()
        settings.mode = scopeMode
        settings.seconds = seconds
        settings.foreground = NSColor(palette.color(.text)).cgColor
        settings.background = NSColor(palette.color(.panel)).cgColor
        settings.grid = NSColor(palette.color(.border)).cgColor

        exportProgress = 0
        exportedTo = nil
        let player = self.player
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SIDVideoExporter.export(tune: tune, player: player, settings: settings, to: url) {
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
        HStack(spacing: 10) {
            Button(player.isPlaying ? "Stop" : "Play") {
                if player.isPlaying { player.stop() } else { loadTune(); player.play() }
            }
            .keyboardShortcut(.defaultAction)
            Button("Reload") { loadTune(); if player.isPlaying { player.play() } }
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

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
    }
}
