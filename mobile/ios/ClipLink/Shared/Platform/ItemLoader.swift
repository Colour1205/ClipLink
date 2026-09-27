import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Something read off the pasteboard (or handed in via Paste / share / picker),
/// on its way to becoming a signed entry.
enum Capture {
    case text(String)
    /// Always PNG: the other platforms exchange images as base64 PNG, and
    /// Windows' System.Drawing can't decode HEIC.
    case image(png: Data)
    case file(URL, name: String)
}

/// Turns item providers (the system Paste control, drag & drop, the Share
/// extension, the photo picker) into a `Capture`. Shared by the app and the
/// extension, so it stays free of app-only API.
enum ItemLoader {
    /// Same priority as a pasteboard read - image, text, URL, then any file.
    static func capture(from providers: [NSItemProvider]) async -> Capture? {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                if let data = await loadData(provider, type: .png) { return .image(png: data) }
                // The original bytes (a photo is often a 12-48 MP HEIC), scaled
                // and re-encoded by ImageIO: far less memory than a UIImage
                // redraw, which matters most in the Share extension.
                if let type = provider.registeredTypeIdentifiers.lazy.compactMap(UTType.init).first(where: { $0.conforms(to: .image) }),
                   let data = await loadData(provider, type: type), let png = Self.pngData(fromImageData: data) {
                    return .image(png: png)
                }
                if let image = await loadImage(provider), let png = Self.pngData(image) { return .image(png: png) }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || provider.canLoadObject(ofClass: NSString.self) {
                if let text = await loadString(provider), !text.isEmpty { return .text(text) }
            }
            if provider.canLoadObject(ofClass: URL.self), let url = await loadURL(provider) {
                if !url.isFileURL { return .text(url.absoluteString) }
                if let capture = copiedFile(url) { return capture }
            }
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            if let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .content) }),
               let (url, name) = await loadFile(provider, type: type) {
                return .file(url, name: name)
            }
        }
        return nil
    }

    static func copiedFile(_ url: URL) -> Capture? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = Self.tempURL(named: url.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: url, to: temp)) != nil else { return nil }
        return .file(temp, name: url.lastPathComponent)
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { c in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in c.resume(returning: data) }
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { c in
            provider.loadObject(ofClass: UIImage.self) { object, _ in c.resume(returning: object as? UIImage) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in c.resume(returning: object as? String) }
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: URL.self) { object, _ in c.resume(returning: object) }
        }
    }

    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> (URL, String)? {
        await withCheckedContinuation { c in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The provided URL is deleted when this callback returns: copy now.
                guard let url else { return c.resume(returning: nil) }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension ?? Optional(url.pathExtension), !ext.isEmpty {
                    name += "." + ext
                }
                let temp = Self.tempURL(named: name)
                do {
                    try FileManager.default.copyItem(at: url, to: temp)
                    c.resume(returning: (temp, name))
                } catch {
                    c.resume(returning: nil)
                }
            }
        }
    }

    static func tempURL(named name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(FileStore.sanitize(name))
    }

    /// Longest edge, in pixels, of an image re-encoded for sending: 12 MP
    /// photos go at full size, bigger ones are scaled down rather than
    /// becoming a 100 MB inline PNG that every history_batch re-sends.
    static let maxImagePixelSize = 4096

    /// PNG with orientation baked in (PNG has no EXIF orientation flag).
    static func pngData(_ image: UIImage) -> Data? {
        if image.imageOrientation == .up, let data = image.pngData() { return data }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        // Not extended range (8 bytes a pixel on wide-colour screens): the
        // PNG is 8-bit anyway.
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.pngData()
    }

    /// Any image bytes (JPEG/HEIC/…) as an upright PNG no larger than
    /// `maxPixelSize` on its long edge. ImageIO only - no UIKit drawing - so it
    /// is safe, and meant, to run off the main thread.
    static func pngData(fromImageData data: Data, maxPixelSize: Int = maxImagePixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let (width, height, orientation) = geometry(of: source)
        let longEdge = max(width, height)
        if (CGImageSourceGetType(source) as String?) == UTType.png.identifier, orientation == 1, longEdge <= maxPixelSize {
            return data
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge > 0 ? min(longEdge, maxPixelSize) : maxPixelSize,
        ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// An image FILE as an inline PNG, or nil when it should travel as the
    /// file itself: more pixels than it can be sent at without scaling down
    /// (a file keeps its full resolution), or a PNG bigger than `maxBytes`.
    /// Off the main thread.
    static func inlinePNG(forImageFileAt url: URL, maxBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let (width, height, _) = geometry(of: source)
        guard width > 0, height > 0, max(width, height) <= maxImagePixelSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let png = pngData(fromImageData: data), png.count <= maxBytes
        else { return nil }
        return png
    }

    /// A small upright preview decoded at reduced size where the format
    /// allows it - cheap on memory, unlike UIImage(data:) on the full image.
    static func thumbnail(ofImageData data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Pixel size and EXIF orientation, from the header alone (no decode).
    private static func geometry(of source: CGImageSource) -> (width: Int, height: Int, orientation: Int) {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props?[kCGImagePropertyPixelHeight] as? Int ?? 0,
                props?[kCGImagePropertyOrientation] as? Int ?? 1)
    }
}
