import Foundation
import CoreGraphics

/// How tall the exported picture is.
enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case p720, p1080, uhd4K
    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }
    var height: Int {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .uhd4K: return 2160
        }
    }
}

/// How wide it is for that height.
enum VideoAspect: String, CaseIterable, Identifiable, Codable {
    case fourThree, sixteenNine
    var id: String { rawValue }
    var label: String { self == .fourThree ? "4:3" : "16:9" }
    var multiplier: Double { self == .fourThree ? 4.0 / 3.0 : 16.0 / 9.0 }
}

enum VideoFormat {
    /// Every pairing comes out even, which is what H.264 wants: 960, 1440 and
    /// 2880 wide at 4:3, and 1280, 1920 and 3840 at 16:9.
    static func size(_ resolution: VideoResolution, _ aspect: VideoAspect) -> CGSize {
        let height = Double(resolution.height)
        return CGSize(width: (height * aspect.multiplier).rounded(), height: height)
    }
}
