import ImageIO
import SwiftUI
import UIKit

/// Decoded, downsampled images keyed by item id + pixel size (Android's
/// ImageCache: 480 px grid, 900 px list, larger for the detail screen).
/// NSCache is thread-safe and empties itself under memory pressure.
final class SyncedThumbnailCache: @unchecked Sendable {
    static let shared = SyncedThumbnailCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func key(_ id: String, _ maxPixel: CGFloat) -> String { "\(id)@\(Int(maxPixel))" }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    private func store(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// No preview past this many pixels (400 MB as a bitmap): not every
    /// format decodes straight to a reduced size, and a compressed picture's
    /// pixel count has little to do with its file size. Photos and
    /// screenshots are far below it.
    static let maxSourcePixels = 100_000_000

    /// ImageIO downsampling, with the EXIF orientation applied - image files
    /// and inline images alike.
    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        // From the header alone. Divided, not multiplied: the numbers are
        // the sender's, and a product could overflow.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width <= maxSourcePixels / height else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// The item's picture at `maxPixel`, decoded off the main thread.
    @MainActor
    func load(_ item: SyncedItem, maxPixel: CGFloat, model: AppModel) async -> UIImage? {
        let key = Self.key(item.id, maxPixel)
        if let hit = image(for: key) { return hit }
        var base64: String?
        var fileData: Data?
        switch item.kind {
        case .image: base64 = item.entry.content
        case .file: fileData = model.imageData(for: item) // memory-mapped, cheap
        default: return nil
        }
        guard base64 != nil || fileData != nil else { return nil }
        let (encoded, mapped) = (base64, fileData)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = mapped ?? encoded.flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }) else {
                return nil
            }
            return SyncedThumbnailCache.decode(data, maxPixel: maxPixel)
        }.value
        if let image { store(image, for: key) }
        return image
    }
}

/// A card's picture: full width, natural aspect ratio up to `maxHeight`
/// (then cropped to fill), with a placeholder while it decodes.
struct SyncedThumbnailView: View {
    let item: SyncedItem
    let maxPixel: CGFloat
    let maxHeight: CGFloat
    let placeholderHeight: CGFloat
    var cornerRadius: CGFloat = Theme.smallRadius
    /// Show "couldn't be decoded" (images) or just nothing (image files).
    var showsFailure = true

    @EnvironmentObject private var model: AppModel
    @State private var loaded: UIImage?
    @State private var failed = false

    var body: some View {
        let key = SyncedThumbnailCache.key(item.id, maxPixel)
        let image = loaded ?? SyncedThumbnailCache.shared.image(for: key)
        Group {
            if let image {
                Color.clear
                    .aspectRatio(max(image.size.width, 1) / max(image.size.height, 1), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .overlay(Image(uiImage: image).resizable().scaledToFill())
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("Synced image")
                    .accessibilityAddTraits(.isImage)
            } else if failed {
                if showsFailure {
                    Label("Image (couldn't be decoded)", systemImage: "photo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(maxWidth: .infinity)
                    .frame(height: placeholderHeight)
                    .overlay(ProgressView())
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: key) {
            guard loaded == nil, SyncedThumbnailCache.shared.image(for: key) == nil else { return }
            if let result = await SyncedThumbnailCache.shared.load(item, maxPixel: maxPixel, model: model) {
                loaded = result
            } else {
                failed = true
            }
        }
    }
}
