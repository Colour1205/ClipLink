import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything a card's context menu and the detail screen can do with an
/// item, in one place so both surfaces behave (and toast) identically.
@MainActor
struct SyncedItemActions {
    let model: AppModel
    let haptics: Bool

    func copy(_ item: SyncedItem) {
        Haptics.tap(haptics)
        model.copy(item)
    }

    func share(_ item: SyncedItem) {
        switch item.kind {
        case .text, .opaque:
            SyncedShareSheet.share([item.entry.content])
        case .link:
            // A URL gets rich previews and "Open in Safari"; fall back to text.
            if let url = Self.linkURL(item) {
                SyncedShareSheet.share([url])
            } else {
                SyncedShareSheet.share([item.entry.content])
            }
        case .image:
            guard let url = model.shareURL(for: item) else {
                model.showToast("Couldn't read that image.")
                return
            }
            SyncedShareSheet.share([url])
        case .file:
            guard let url = model.shareURL(for: item) else {
                model.showToast("That file hasn't finished transferring yet.")
                return
            }
            SyncedShareSheet.share([url])
        }
    }

    func openLink(_ item: SyncedItem) {
        guard let url = Self.linkURL(item) else { return }
        UIApplication.shared.open(url)
    }

    func saveToPhotos(_ item: SyncedItem) {
        guard let data = model.imageData(for: item) else {
            model.showToast(item.kind == .file && !item.fileAvailable
                ? "That file hasn't finished transferring yet."
                : "Couldn't save the image.")
            return
        }
        SyncedPhotoSaver.save(data)
    }

    func quickLook(_ item: SyncedItem) {
        guard let url = model.shareURL(for: item) else {
            model.showToast("That file hasn't finished transferring yet.")
            return
        }
        SyncedQuickLookController.present(url)
    }

    func saveToFiles(_ item: SyncedItem) {
        guard let url = model.shareURL(for: item) else {
            model.showToast("That file hasn't finished transferring yet.")
            return
        }
        SyncedDocumentExporter.export(url)
    }

    func delete(_ item: SyncedItem) {
        Haptics.tap(haptics)
        model.delete(item)
    }

    /// Drag-out payload: text, a URL, PNG bytes, or the file itself.
    func dragProvider(for item: SyncedItem) -> NSItemProvider {
        switch item.kind {
        case .text, .opaque:
            return NSItemProvider(object: item.entry.content as NSString)
        case .link:
            if let url = Self.linkURL(item) { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: item.entry.content as NSString)
        case .image:
            let content = item.entry.content
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(Data(base64Encoded: content, options: .ignoreUnknownCharacters), nil)
                return nil
            }
            provider.suggestedName = "ClipLink Image"
            return provider
        case .file:
            guard item.fileAvailable, let url = model.shareURL(for: item),
                  let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
            provider.suggestedName = item.filePayload?.fileName
            return provider
        }
    }

    // MARK: - Item facts

    static func linkURL(_ item: SyncedItem) -> URL? {
        guard item.kind == .link else { return nil }
        return URL(string: item.entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isImageFile(_ item: SyncedItem) -> Bool {
        item.kind == .file && AppModel.isImageFileName(item.filePayload?.fileName ?? "")
    }

    /// Items with pixels to show: images, and image files that have arrived.
    static func hasPicture(_ item: SyncedItem) -> Bool {
        item.kind == .image || (isImageFile(item) && item.fileAvailable)
    }

    static func canSaveToPhotos(_ item: SyncedItem) -> Bool { hasPicture(item) }

    /// "Transferring… 42%", "Transferring…", or the file's size.
    static func fileStatus(_ item: SyncedItem, transfers: [String: TransferProgress]) -> String {
        guard let payload = item.filePayload else { return "" }
        if let progress = transferFraction(item, transfers: transfers) {
            return "Transferring… \(Int((progress * 100).rounded(.down)))%"
        }
        if !item.fileAvailable { return "Transferring…" }
        return ByteSize.format(payload.fileSize)
    }

    static func transferFraction(_ item: SyncedItem, transfers: [String: TransferProgress]) -> Double? {
        guard !item.fileAvailable, let payload = item.filePayload,
              let progress = transfers[FileStore.key(payload.fileHash)], progress.total > 0 else { return nil }
        return min(1, max(0, Double(progress.received) / Double(progress.total)))
    }

    /// SF Symbol for a file name, by extension.
    static func fileSymbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc.fill" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .text) { return "doc.plaintext" }
        return "doc.fill"
    }

    /// VoiceOver summary for a card.
    static func accessibilitySummary(_ item: SyncedItem, transfers: [String: TransferProgress]) -> String {
        var parts = [item.kind.label]
        switch item.kind {
        case .text, .link: parts.append(String(item.entry.content.prefix(200)))
        case .file:
            parts.append(item.filePayload?.fileName ?? "File")
            parts.append(fileStatus(item, transfers: transfers))
        case .opaque, .image: break
        }
        parts.append(TimeLabel.short(item.date))
        parts.append(item.isOwn ? "From this device" : "From \(item.sourceLabel)")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Shared context-menu items for a card (and the detail screen's More menu).
struct SyncedItemMenuItems: View {
    let item: SyncedItem
    let actions: SyncedItemActions

    var body: some View {
        Button { actions.copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        if item.kind == .link {
            Button { actions.openLink(item) } label: { Label("Open Link", systemImage: "safari") }
        }
        Button { actions.share(item) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        if SyncedItemActions.canSaveToPhotos(item) {
            Button { actions.saveToPhotos(item) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
        }
        if item.kind == .file {
            Button { actions.quickLook(item) } label: { Label("Quick Look", systemImage: "eye") }
            Button { actions.saveToFiles(item) } label: { Label("Save to Files", systemImage: "folder") }
        }
        Divider()
        Button(role: .destructive) { actions.delete(item) } label: { Label("Delete", systemImage: "trash") }
    }
}
