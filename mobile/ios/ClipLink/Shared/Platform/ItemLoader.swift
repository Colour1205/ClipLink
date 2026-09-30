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

/// What one "Share → ClipLink" hands over (see `ItemLoader.shareCaptures`).
struct SharedItems {
    /// In the order shared.
    var captures: [Capture] = []
    /// Files over the 1 GB every platform syncs at most, by name - never copied.
    var tooLarge: [String] = []
    var folders = 0
    /// Items there was no reading at all.
    var unreadable = 0
    /// Items past the limit, never read.
    var skipped = 0
}

/// Turns item providers (the system Paste control, drag & drop, the Share
/// extension, the photo picker) into a `Capture`. Shared by the app and the
/// extension, so it stays free of app-only API.
enum ItemLoader {
    /// Same priority as a pasteboard read - image, text, URL, then any file.
    static func capture(from providers: [NSItemProvider]) async -> Capture? {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                // Not an empty .png file: that goes as the (empty) file below.
                if let data = await loadData(provider, type: .png), !data.isEmpty { return .image(png: data) }
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

    /// Everything one "Share → ClipLink" hands over, synced the way every
    /// platform syncs a share: each item the system passes as a FILE (from
    /// Files, Photos, Mail...) goes as that file - its own bytes and name,
    /// an image file included; an image with no file behind it (a screenshot
    /// being marked up, a picture held by a web view) as an inline image,
    /// like a copy; and text or a link only when nothing else came with it -
    /// the caption or page link an app attaches to what it shares isn't the
    /// thing being shared. At most `limit` items are read: the history holds
    /// no more, and the first ones would be evicted - their bytes deleted -
    /// before a peer could fetch them. Cancelling the task stops it after
    /// the item being read.
    static func shareCaptures(from providers: [NSItemProvider], limit: Int) async -> SharedItems {
        var items = SharedItems()
        var text: Capture?
        for provider in providers {
            if Task.isCancelled { break }
            guard items.captures.count < limit else {
                items.skipped += 1
                continue
            }
            let file = await sharedFile(from: provider)
            switch file {
            case .copied(let url, let name):
                items.captures.append(.file(url, name: name))
            case .tooLarge(let name):
                items.tooLarge.append(name)
            case .folder:
                items.folders += 1
            case .unreadable:
                items.unreadable += 1
            case .notAFile:
                let loaded = await capture(from: [provider])
                switch loaded {
                case .some(.text):
                    if text == nil { text = loaded }
                case .some(let other):
                    items.captures.append(other)
                case .none:
                    items.unreadable += 1
                }
            }
        }
        if items.captures.isEmpty, let text { items.captures = [text] }
        return items
    }

    private enum SharedFile {
        case copied(URL, name: String)
        case tooLarge(String)
        case folder
        case unreadable
        /// Nothing on disk behind it: text, a web link, an image in memory.
        case notAFile
    }

    /// The provider's own file, when it hands one over, copied now under its
    /// own name. `loadItem` gives the file itself (a file URL) for anything
    /// that is one - a photo from Photos too - and the object or bytes for
    /// anything that isn't.
    private static func sharedFile(from provider: NSItemProvider) async -> SharedFile {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        // A picture's own type first, not a bundle or preview listed with it.
        guard let type = types.first(where: { $0.conforms(to: .image) })
                ?? types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .content) })
        else { return .notAFile }
        let result: SharedFile? = await withCheckedContinuation { c in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                // Copied inside the handler: the URL needn't outlive it.
                guard let url = item as? URL, url.isFileURL else { return c.resume(returning: .notAFile) }
                c.resume(returning: Self.copySharedFile(url, suggestedName: provider.suggestedName))
            }
        }
        if let result { return result }
        // It is a file, just not one this process may open directly: the
        // provider's own copy then.
        guard let (url, name) = await loadFile(provider, type: type) else { return .unreadable }
        return .copied(url, name: name)
    }

    /// Nil when the copy itself failed. Folders (and packages) aren't synced
    /// on any platform, and nothing over 1 GB is copied at all.
    private static func copySharedFile(_ url: URL, suggestedName: String?) -> SharedFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = sharedFileName(url, suggested: suggestedName)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return .folder }
        if let size = values?.fileSize, Int64(size) > Wire.maxFileBytes { return .tooLarge(name) }
        let temp = tempURL(named: name)
        guard (try? FileManager.default.copyItem(at: url, to: temp)) != nil else {
            discardTemp(temp)
            return nil
        }
        return .copied(temp, name: name)
    }

    /// A shared file goes out under its own name - its extension always
    /// matches the bytes - unless the provider suggests a bare name of its
    /// own: the name on disk isn't always the one the user knows (Photos
    /// keeps an edited photo as "FullSizeRender.jpg").
    private static func sharedFileName(_ url: URL, suggested: String?) -> String {
        let own = url.lastPathComponent
        guard let suggested = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty,
              (suggested as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty
        else { return own }
        return suggested + "." + url.pathExtension
    }

    /// Removes a capture's temporary copy (see `tempURL`), if it has one.
    static func discard(_ capture: Capture) {
        guard case .file(let url, _) = capture else { return }
        discardTemp(url)
    }

    static func discardTemp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix("capture-") else { return }
        try? FileManager.default.removeItem(at: dir)
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(of: source, maxPixelSize: maxPixelSize)
    }

    /// The same for an image FILE - nil for a picture so big that decoding
    /// it, even scaled down, could take more memory than the Share
    /// extension has.
    static func thumbnail(ofImageFileAt url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let (width, height, _) = geometry(of: source)
        // Divided, not multiplied: a header's numbers could overflow a product.
        guard width > 0, height > 0, width <= maxPreviewPixels / height else { return nil }
        return thumbnail(of: source, maxPixelSize: maxPixelSize)
    }

    static let maxPreviewPixels = 24_000_000

    private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary) else { return nil }
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
