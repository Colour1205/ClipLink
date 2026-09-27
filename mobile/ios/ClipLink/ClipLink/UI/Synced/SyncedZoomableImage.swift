import SwiftUI
import UIKit

/// A detail-screen picture: decoded off the main thread at up to 2400 px,
/// then shown in a pinch-to-zoom (1-4x), double-tap-to-zoom scroll view.
struct SyncedZoomableImageView: View {
    let item: SyncedItem

    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?
    @State private var failed = false

    private static let maxPixel: CGFloat = 2400

    var body: some View {
        let key = SyncedThumbnailCache.key(item.id, Self.maxPixel)
        let shown = image ?? SyncedThumbnailCache.shared.image(for: key)
        ZStack {
            if let shown {
                SyncedZoomableImage(image: shown)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("This image couldn't be decoded.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
                    .accessibilityLabel("Loading image")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) {
            guard image == nil, SyncedThumbnailCache.shared.image(for: key) == nil else { return }
            if let result = await SyncedThumbnailCache.shared.load(item, maxPixel: Self.maxPixel, model: model) {
                image = result
            } else {
                failed = true
            }
        }
    }
}

struct SyncedZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> SyncedZoomScrollView { SyncedZoomScrollView() }

    func updateUIView(_ view: SyncedZoomScrollView, context: Context) {
        view.setImage(image)
    }
}

final class SyncedZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Synced image"
        imageView.accessibilityHint = "Pinch or double-tap to zoom."
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fitImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize { fitImage() }
    }

    /// Back to 1x with the whole picture fitted and centred.
    private func fitImage() {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        laidOutSize = bounds.size
        zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private func centerImage() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let target: CGFloat = 2.5
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
