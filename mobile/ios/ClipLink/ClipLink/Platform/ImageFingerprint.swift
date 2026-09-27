import CoreGraphics
import Foundation
import ImageIO

/// A tiny perceptual fingerprint (pixel size + 8×8 average hash) that survives
/// re-encoding. Used for one thing: when we send an image, the Windows daemon
/// applies it, GDI+ re-encodes it on its next clipboard poll, and its hash
/// check no longer recognises it - so it broadcasts our own image straight
/// back as a new Windows entry. Matching fingerprints lets us ignore that
/// echo instead of re-applying it.
struct ImageFingerprint: Equatable {
    let width: Int
    let height: Int
    let hash: UInt64

    init?(imageData: Data) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: 64)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return nil }
        let mean = pixels.reduce(0) { $0 + Int($1) } / 64
        var bits: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) >= mean { bits |= 1 << UInt64(i) }
        width = w
        height = h
        hash = bits
    }

    func looksLike(_ other: ImageFingerprint) -> Bool {
        width == other.width && height == other.height && (hash ^ other.hash).nonzeroBitCount <= 4
    }
}
