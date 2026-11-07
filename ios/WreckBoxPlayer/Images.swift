import UIKit

/// Covers: a phone song's own picture ("file:<name>") or a web image (YouTube / Spotify), decoded at the size asked for and kept in a small memory cache.
actor Images {
    static let shared = Images()
    private let cache: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 32 << 20; return c }()

    func load(_ art: String?, size: CGFloat) async -> UIImage? {
        guard let art, !art.isEmpty else { return nil }
        let px = size <= 64 ? 128 : size <= 160 ? 320 : 768
        let key = "\(art)#\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var data: Data?
        if art.hasPrefix("file:") {
            data = await LocalFiles.artwork(String(art.dropFirst(5)))
        } else if let url = URL(string: Self.sized(art, px)) {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let img = Self.downscale(data, px) else { return nil }
        cache.setObject(img, forKey: key, cost: px * px * 4)
        return img
    }

    /// YouTube covers come in any size (=wN-hN).
    private static func sized(_ url: String, _ px: Int) -> String {
        url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w\(px)-h\(px)", options: .regularExpression)
    }

    private static func downscale(_ data: Data, _ px: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: px,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
