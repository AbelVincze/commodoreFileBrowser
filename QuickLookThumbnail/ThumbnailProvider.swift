import QuickLookThumbnailing
import CoreGraphics

/// Finder icons for Amiga pictures.
///
/// The whole extension: read the file, decode it, draw it. It compiles
/// `Shared/Picture` and nothing else — no audio, no emulator, no C — because a
/// thumbnail is wanted for a folder of files at once and the system will not
/// wait around while something warms up.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let picture: ILBMImage
        do {
            let bytes = [UInt8](try Data(contentsOf: request.fileURL, options: .mappedIfSafe))
            // `.iff` covers pictures and samples alike, so both arrive here.
            // A sample has no picture in it: no thumbnail rather than a
            // placeholder, which leaves Finder's own icon in place.
            guard let form = IFFLoader.detect(bytes), form.isPicture else {
                handler(nil, nil)
                return
            }
            picture = try ILBMDecoder.decode(bytes)
        } catch {
            handler(nil, error)
            return
        }

        // Drawn at the shape it was meant to have. An Amiga pixel was not
        // square, and a 320x200 lores picture shown square is visibly squat.
        let width = CGFloat(picture.width)
        let height = CGFloat(picture.height) * picture.heightScale
        guard width > 0, height > 0 else { handler(nil, nil); return }

        let maximum = request.maximumSize
        let scale = min(maximum.width / width, maximum.height / height)
        let size = CGSize(width: max(1, (width * scale).rounded()),
                          height: max(1, (height * scale).rounded()))

        let image = picture.image
        handler(QLThumbnailReply(contextSize: size) { context -> Bool in
            // Nearest neighbour: these are pictures drawn a pixel at a time,
            // and smoothing them is a lie about how much detail is there.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }
}
