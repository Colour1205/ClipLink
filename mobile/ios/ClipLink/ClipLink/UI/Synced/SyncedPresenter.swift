import Photos
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Presents system view controllers (share sheet, Quick Look, document
/// pickers, photo picker) straight from the top-most UIKit controller.
///
/// Going through UIKit instead of SwiftUI's `.sheet` gives the share sheet its
/// native half-height presentation on iOS 15, keeps presentation modifiers off
/// the (lazily recycled) cards, and sidesteps iOS 15's "several presentation
/// modifiers on one view" bug entirely.
@MainActor
enum SyncedPresenter {
    static func present(_ controller: UIViewController, attempt: Int = 0) {
        guard let root = keyWindow()?.rootViewController else { return }
        var top = root
        var busy = false
        while let next = top.presentedViewController {
            if next.isBeingDismissed {
                busy = true
                break
            }
            top = next
        }
        if busy || top.transitionCoordinator != nil {
            // A menu, sheet or push is still animating - present once it's done.
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    present(controller, attempt: attempt + 1)
                }
            }
            return
        }
        if let popover = controller.popoverPresentationController, let view = top.view {
            // iPad: no toolbar button to anchor to from SwiftUI, so float it.
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        return active.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? active.first?.windows.first
            ?? scenes.first?.windows.first
    }
}

// MARK: - Share sheet

@MainActor
enum SyncedShareSheet {
    static func share(_ items: [Any]) {
        guard !items.isEmpty else { return }
        SyncedPresenter.present(UIActivityViewController(activityItems: items, applicationActivities: nil))
    }
}

// MARK: - Quick Look

/// A Quick Look controller that is its own data source, so nothing else has
/// to stay alive while it's on screen.
final class SyncedQuickLookController: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }

    @MainActor
    static func present(_ url: URL) {
        SyncedPresenter.present(SyncedQuickLookController(url: url))
    }
}

// MARK: - Save to Files

/// "Save to Files": the system export picker, copying the file out.
@MainActor
final class SyncedDocumentExporter: NSObject, UIDocumentPickerDelegate {
    private static var active: SyncedDocumentExporter?

    static func export(_ url: URL) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = SyncedDocumentExporter()
        picker.delegate = delegate
        active = delegate
        SyncedPresenter.present(picker)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        AppModel.shared.showToast("Saved to Files.")
        Self.active = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.active = nil
    }
}

// MARK: - Send from Files

/// "Send › Files": the system open picker. `asCopy` hands us a private copy,
/// so there is no security scope to juggle and the copy can be removed as
/// soon as the model has taken its own.
@MainActor
final class SyncedDocumentImporter: NSObject, UIDocumentPickerDelegate {
    private static var active: SyncedDocumentImporter?

    static func present() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = SyncedDocumentImporter()
        picker.delegate = delegate
        active = delegate
        SyncedPresenter.present(picker)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Self.active = nil
        guard let url = urls.first else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            AppModel.shared.showToast("Folders can't be sent — pick a file instead.")
            return
        }
        AppModel.shared.sendFile(at: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.active = nil
    }
}

// MARK: - Send from Photos

/// "Send › Photo Library": PHPicker needs no photo-library permission.
@MainActor
final class SyncedPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private static var active: SyncedPhotoPicker?

    static func present() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = SyncedPhotoPicker()
        picker.delegate = delegate
        active = delegate
        SyncedPresenter.present(picker)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        Self.active = nil
        guard let provider = results.first?.itemProvider else { return }
        let type = UTType.image.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            AppModel.shared.showToast("Couldn't read that image.")
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            Task { @MainActor in
                if let data {
                    AppModel.shared.sendImageData(data)
                } else {
                    AppModel.shared.showToast("Couldn't read that image.")
                }
            }
        }
    }
}

// MARK: - Save to Photos

/// Add-only Photos access (NSPhotoLibraryAddUsageDescription): the original
/// bytes first, so GIFs and HEICs stay what they are; a re-encode if Photos
/// doesn't take the format (WebP, BMP).
enum SyncedPhotoSaver {
    static func save(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                toast("ClipLink can't add to Photos — allow it in Settings › Privacy & Security › Photos.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { saved, _ in
                if saved {
                    toast("Saved to Photos.")
                    return
                }
                guard let image = UIImage(data: data) else {
                    toast("Couldn't save the image.")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { savedAgain, _ in
                    toast(savedAgain ? "Saved to Photos." : "Couldn't save the image.")
                }
            }
        }
    }

    private static func toast(_ message: String) {
        Task { @MainActor in AppModel.shared.showToast(message) }
    }
}
