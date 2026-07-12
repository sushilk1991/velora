import Foundation

/// One-time bridge for the App ID transition required by iCloud Documents.
enum PreferencesDomainMigration {
    static let legacyBundleIdentifier = "com.velora.app"
    static let currentBundleIdentifier = "com.sushil.velora"
    private static let completionKey = "velora.preferencesDomainMigration.v1"

    @discardableResult
    static func run(
        sourceDomain: String = legacyBundleIdentifier,
        destinationDomain: String = currentBundleIdentifier,
        destination: UserDefaults = .standard
    ) -> Int {
        let existing = destination.persistentDomain(forName: destinationDomain) ?? [:]
        guard existing[completionKey] as? Bool != true else { return 0 }

        let legacy = destination.persistentDomain(forName: sourceDomain) ?? [:]
        var migrated = existing
        var copied = 0
        for (key, value) in legacy where key.hasPrefix("velora.") {
            guard key != completionKey, existing[key] == nil else { continue }
            migrated[key] = value
            copied += 1
        }
        migrated[completionKey] = true
        destination.setPersistentDomain(migrated, forName: destinationDomain)
        return copied
    }
}
