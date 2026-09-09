import Foundation

/// The one door into `Shared/Picture`.
///
/// Two families of picture live behind it — the Amiga's chunked IFF and the
/// C64's fixed memory dumps — and nothing above this needs to know which a
/// file is. The viewer asks for a picture, the thumbnail extension asks
/// whether there is one, and the answer is the same shape either way.
enum PictureLoader {

    /// What kind of picture a file holds.
    enum Kind {
        case iff(IFFForm)
        case c64(C64PictureFormat)

        var name: String {
            switch self {
            case .iff(let form): return form.name
            case .c64(let format): return format.name
            }
        }
    }

    /// A picture in these bytes, or nil. Content first and always: an Amiga
    /// file is as likely to be called `pic.1` as anything else, and a C64
    /// picture pulled off a D64 is as likely to be called `PIC A`.
    static func detect(name: String, bytes: [UInt8]) -> Kind? {
        if let form = IFFLoader.detect(bytes) {
            return form.isPicture ? .iff(form) : nil
        }
        if let format = C64Picture.detect(name: name, bytes: bytes) { return .c64(format) }
        return nil
    }

    /// The picture itself, or the reason there isn't one.
    ///
    /// An IFF says so in its own header and its failures are worth reporting
    /// as they come; a C64 picture is recognised by its size alone, so a file
    /// that is not one has nothing to report beyond that.
    static func decode(name: String, bytes: [UInt8]) throws -> DecodedPicture {
        if IFF.form(bytes) != nil {
            var picture = try ILBMDecoder.decode(bytes)
            if case .anim(let frames)? = IFFLoader.detect(bytes) {
                picture.format = "IFF ANIM"
                picture.mode += " · first of \(frames) frames"
            }
            return picture
        }
        return try C64Picture.decode(name: name, bytes: bytes)
    }
}
