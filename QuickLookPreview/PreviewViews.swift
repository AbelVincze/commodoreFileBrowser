import SwiftUI

/// The space around everything in a preview. Quick Look sizes its window from
/// what the view asks for, so a view that stretches to fill gets a window the
/// size of the screen with the content adrift in the middle of it.
let previewPadding: CGFloat = 24

/// The largest a picture is drawn at. Past this the window is unwieldy, and a
/// picture bigger than this is shrunk to fit rather than cropped.
let previewPictureBox = CGSize(width: 720, height: 520)

/// A picture, at the shape it was drawn as.
struct PicturePreview: View {
    let name: String
    let picture: ILBMImage
    let form: IFFForm

    var body: some View {
        VStack(spacing: 10) {
            let size = picture.displaySize(within: previewPictureBox)
            Image(nsImage: PixelImage.image(picture.image))
                .resizable()
                // Nearest neighbour: a picture drawn a pixel at a time should
                // not be smoothed into looking like it has more detail.
                .interpolation(.none)
                .frame(width: size.width, height: size.height)
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: size.width)
        }
        .padding(previewPadding)
    }

    private var caption: String {
        var parts = [name, "\(picture.width) × \(picture.height)", picture.mode]
        if case .anim(let frames) = form { parts.append("first of \(frames) frames") }
        return parts.joined(separator: " · ")
    }
}

/// A tune, a module or a sample: what it is, and a transport.
///
/// It starts playing on its own, so the button is there to stop it rather than
/// to start it. Everything is in system colours — a preview has no settings
/// store to read a palette from, and matching the rest of Quick Look is the
/// right look anyway.
struct SoundPreview: View {
    enum Engine {
        case sid(SIDPlayer)
        case module(ModulePlayer)
        case sample(SamplePlayer)
        case none
    }

    let name: String
    let detail: String
    let player: Engine

    /// Wide enough for a tracker's worth of detail on one line, and no taller
    /// than what is in it.
    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            transport
        }
        .padding(previewPadding)
        .frame(width: Self.width, alignment: .leading)
    }

    private var icon: String {
        switch player {
        case .sid: return "waveform.circle"
        case .module: return "music.note.list"
        case .sample: return "waveform"
        case .none: return "questionmark.circle"
        }
    }

    @ViewBuilder
    private var transport: some View {
        switch player {
        case .sid(let p): SIDTransport(player: p)
        case .module(let p): ModuleTransport(player: p)
        case .sample(let p): SampleTransport(player: p)
        case .none: EmptyView()
        }
    }
}

// Three all but identical transports rather than one generic: the players
// share no protocol, and a protocol invented for three buttons would be more
// machinery than the three buttons.

private struct SIDTransport: View {
    @ObservedObject var player: SIDPlayer
    var body: some View {
        PlayButton(isPlaying: player.isPlaying) { player.isPlaying ? player.pause() : player.play() }
    }
}

private struct ModuleTransport: View {
    @ObservedObject var player: ModulePlayer
    var body: some View {
        HStack(spacing: 10) {
            PlayButton(isPlaying: player.isPlaying) { player.toggle() }
            if player.duration > 0 {
                ProgressView(value: min(player.position, player.duration), total: player.duration)
                    .frame(maxWidth: 200)
                Text(clock(player.position) + " / " + clock(player.duration))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SampleTransport: View {
    @ObservedObject var player: SamplePlayer
    var body: some View {
        HStack(spacing: 10) {
            PlayButton(isPlaying: player.isPlaying) { player.toggle() }
            if player.duration > 0 {
                ProgressView(value: min(player.position, player.duration), total: player.duration)
                    .frame(maxWidth: 200)
                Text(String(format: "%.1fs / %.1fs", player.position, player.duration))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(isPlaying ? "Pause" : "Play")
    }
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let whole = Int(seconds)
    return String(format: "%d:%02d", whole / 60, whole % 60)
}
