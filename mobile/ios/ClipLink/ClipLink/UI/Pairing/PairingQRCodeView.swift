import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// This device's pairing QR: always black modules on a white box, even in
/// dark mode, so every scanner (Android's ZXing, HarmonyOS' system scanner)
/// reads it.
struct PairingQRCodeView: View {
    let payload: String
    var side: CGFloat = 216

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
            if let image = PairingQRGenerator.image(for: payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .accessibilityLabel("Pairing QR code")
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                    Text("Generating…")
                        .font(.footnote)
                        .foregroundColor(.black.opacity(0.6))
                }
            }
        }
        .frame(width: side + 24, height: side + 24)
        .environment(\.colorScheme, .light)
    }
}

/// CoreImage QR rendering with a one-entry cache: the snapshot republishes
/// often, the payload rarely changes.
@MainActor
enum PairingQRGenerator {
    private static let context = CIContext()
    private static var cached: (payload: String, image: UIImage)?

    static func image(for payload: String) -> UIImage? {
        guard !payload.isEmpty else { return nil }
        if let cached, cached.payload == payload { return cached.image }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer upscale so every module stays a crisp square.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cached = (payload, image)
        return image
    }
}
