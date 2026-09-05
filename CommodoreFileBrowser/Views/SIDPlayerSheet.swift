import SwiftUI

/// What the browser hands the player: the file, and whether its addresses were
/// worked out or have to be typed in.
struct SIDRequest: Identifiable {
    let id = UUID()
    var name: String
    var data: [UInt8]
    /// Nil when nothing could be detected, or when detection was skipped.
    var detected: SIDTune?
}

/// The load form and the transport in one sheet. Closing it stops playback.
struct SIDPlayerSheet: View {
    let request: SIDRequest
    let palette: Palette
    @ObservedObject var player: SIDPlayer
    let onClose: () -> Void

    @State private var initText: String
    @State private var playText: String
    @State private var speedText: String
    @State private var loadError: String?

    private static let speedPresets: [Double] = [0, 50, 100, 200, 400]

    init(request: SIDRequest, palette: Palette, player: SIDPlayer, onClose: @escaping () -> Void) {
        self.request = request
        self.palette = palette
        _player = ObservedObject(wrappedValue: player)
        self.onClose = onClose
        _initText = State(initialValue: String(format: "%04X", request.detected?.initAddress ?? 0x1000))
        _playText = State(initialValue: String(format: "%04X", request.detected?.playAddress ?? 0x1003))
        _speedText = State(initialValue: "0")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            form
            Divider().overlay(palette.color(.border))
            transport
        }
        .frame(width: 460)
        .background(palette.color(.window))
        .onAppear { loadTune() }
        .onDisappear { player.stop() }
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
            parts.append(String(format: "load $%04X", tune.loadAddress))
        } else {
            parts.append("addresses not detected — enter them below")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                field("Init", text: $initText)
                field("Play", text: $playText)
                Spacer(minLength: 0)
            }
            Text("Play $0000 lets the tune install its own interrupt.")
                .font(.system(size: 9))
                .foregroundStyle(palette.color(.dim))

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
        player.load(tune)
    }
}
