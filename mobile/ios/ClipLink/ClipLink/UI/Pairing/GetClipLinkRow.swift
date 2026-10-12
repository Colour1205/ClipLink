import SwiftUI

/// The website: the downloads for Windows, Android, HarmonyOS and iOS.
enum ClipLinkWebsite {
    static let host = "cliplink.uaena.io"
    static let url = URL(string: "https://cliplink.uaena.io/")!
}

/// "Get ClipLink on your other devices": the website's address, a tap opens it
/// in the browser. On the Devices tab and the pairing sheet, where it comes up
/// that the other device does not have ClipLink yet.
struct GetClipLinkRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Link(destination: ClipLinkWebsite.url) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundColor(settings.accentTheme.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get ClipLink on your other devices")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Text(ClipLinkWebsite.host)
                        .font(.subheadline)
                        .foregroundColor(settings.accentTheme.color)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens the ClipLink website in your browser")
    }
}
