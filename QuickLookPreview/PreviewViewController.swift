import Cocoa
import QuickLookUI
import SwiftUI

/// Space bar on a tune, a module, a sample or a picture.
///
/// Quick Look opens and closes a preview every time the arrow keys move in
/// Finder, so the two rules here are: decide what the file is from its own
/// bytes and nothing else, and stop the sound on the way out. A tune left
/// running would stack up one per file walked past.
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Whichever engine this preview started, kept only so it can be stopped.
    private var stop: (() -> Void)?

    override func loadView() {
        // A modest starting size. What the window actually becomes is set in
        // `show`, from what the content asks for.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 140))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        let name = url.lastPathComponent

        // A `FORM` header is unambiguous, so it is asked first. The browser
        // tries SID before IFF only because that was the order its Return key
        // grew up in; here there is no history to keep.
        if let form = IFFLoader.detect(bytes) {
            if form.isPicture {
                let picture = try PictureLoader.decode(name: name, bytes: bytes)
                show(PicturePreview(name: name, picture: picture))
                return
            }
            let sound = try EightSVXDecoder.decode(bytes)
            let player = SamplePlayer()
            player.load(sound, owner: UUID())
            stop = { [weak player] in player?.unload() }
            player.play()
            show(SoundPreview(name: sound.name ?? name,
                              detail: sampleDetail(sound),
                              player: .sample(player)))
            return
        }

        if let tune = SIDTuneLoader.detect(name: name, data: bytes) {
            let player = SIDPlayer()
            player.load(tune)
            stop = { [weak player] in player?.stop() }
            player.play()
            show(SoundPreview(name: tune.title.isEmpty ? name : tune.title,
                              detail: tuneDetail(tune),
                              player: .sid(player)))
            return
        }

        if let module = ModuleLoader.detect(bytes) {
            let player = ModulePlayer()
            guard player.load(module, owner: UUID()) else {
                // Recognised but unplayable — some Amiga chiptune formats have
                // no engine here. Say which it is rather than showing nothing.
                show(SoundPreview(name: name,
                                  detail: "\(module.format.name) · no player for this format",
                                  player: .none))
                return
            }
            stop = { [weak player] in player?.unload() }
            player.play()
            show(SoundPreview(name: module.title.isEmpty ? name : module.title,
                              detail: moduleDetail(module, player: player),
                              player: .module(player)))
            return
        }

        // Last, because it is the only guess in here: a C64 picture has no
        // header saying so and is recognised by its size and load address
        // alone, which is a weaker claim than any of the above.
        if C64Picture.detect(name: name, bytes: bytes) != nil {
            let picture = try PictureLoader.decode(name: name, bytes: bytes)
            show(PicturePreview(name: name, picture: picture))
            return
        }

        throw CocoaError(.fileReadCorruptFile)
    }

    // MARK: - Detail lines

    private func tuneDetail(_ tune: SIDTune) -> String {
        var parts = ["from the \(tune.source.rawValue)"]
        if let author = tune.author { parts.append(author) }
        switch tune.songCount {
        case nil: parts.append("multiple songs")
        case let count? where count > 1: parts.append("\(count) songs")
        default: break
        }
        parts.append(String(format: "init $%04X", tune.initAddress))
        parts.append(String(format: "play $%04X", tune.playAddress))
        return parts.joined(separator: " · ")
    }

    private func moduleDetail(_ module: Module, player: ModulePlayer) -> String {
        var parts = [module.format.name]
        let tracker = player.tracker.trimmingCharacters(in: .whitespaces)
        if !tracker.isEmpty, tracker != module.format.name { parts.append(tracker) }
        if player.channels > 0 { parts.append("\(player.channels) channels") }
        if player.samples > 0 { parts.append("\(player.samples) samples") }
        return parts.joined(separator: " · ")
    }

    private func sampleDetail(_ sound: SampledSound) -> String {
        var parts = ["IFF 8SVX", "\(Int(sound.sampleRate)) Hz",
                     String(format: "%.2fs", sound.duration)]
        if sound.loop != nil { parts.append("looping") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Hosting

    /// Puts a view on screen and sizes the window to it.
    ///
    /// Quick Look asks the controller how big it would like to be and, told
    /// nothing, gives it something enormous — which is how the first version
    /// ended up a screenful of black with a line of text adrift in the middle.
    /// Every preview here has a size it wants: a picture is as big as the
    /// picture, and a tune is as tall as the two lines and a play button that
    /// describe it.
    private func show<Content: View>(_ content: Content) {
        let hosting = NSHostingView(rootView: content)
        let wanted = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: wanted)
        hosting.autoresizingMask = [.width, .height]

        view.subviews.forEach { $0.removeFromSuperview() }
        view.setFrameSize(wanted)
        view.addSubview(hosting)
        preferredContentSize = wanted
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stop?()
        stop = nil
    }

    deinit { stop?() }
}
