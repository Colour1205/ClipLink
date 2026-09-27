import Foundation

/// Storage shared by the app and its Share extension. Both run the same sync
/// engine over the same history, trust store and file blobs, so the App Group
/// container is the single home for all of it.
enum SharedContainer {
    static let appGroupID = "group.io.uaena.ClipLink"

    /// Nil when the App Group entitlement isn't provisioned (e.g. signing not
    /// set up for the group yet) - the app then falls back to its own sandbox
    /// and the Share extension can't work.
    static var groupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var isAvailable: Bool { groupURL != nil }

    /// Where the engine keeps its files. The app migrates anything it stored
    /// before the App Group existed (Application Support/ClipLink) on first use.
    static func storageDirectory(migrateLegacy: Bool) -> URL {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLink", isDirectory: true)
        guard let group = groupURL else {
            prepare(legacy)
            return legacy
        }
        let dir = group.appendingPathComponent("ClipLink", isDirectory: true)
        prepare(dir)
        if migrateLegacy, fm.fileExists(atPath: legacy.path),
           !fm.fileExists(atPath: dir.appendingPathComponent("history.json").path),
           !fm.fileExists(atPath: dir.appendingPathComponent("trusted_devices.json").path) {
            for item in (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
                let target = dir.appendingPathComponent(item.lastPathComponent)
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: item, to: target)
            }
            try? fm.removeItem(at: legacy)
        }
        return dir
    }

    /// Created, and excluded from backups: history holds clipboard contents,
    /// and trust/identity-bound state is meaningless on another device.
    private static func prepare(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
