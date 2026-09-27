// swift-tools-version:5.9
//
// Test harness only - NOT part of the app. It compiles the app's own
// ClipLink/Core sources (via the Sources/ClipLinkCore symlink) for macOS so
// the protocol/crypto interop tests and the two-engine loopback tests run
// with `swift test`, no simulator or device needed. The app target builds the
// same files directly from ClipLink/Core.
import PackageDescription

let package = Package(
    name: "ClipLinkCoreTests",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "ClipLinkCore", path: "Sources/ClipLinkCore"),
        .testTarget(name: "ClipLinkCoreTests", dependencies: ["ClipLinkCore"], path: "Tests/ClipLinkCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
