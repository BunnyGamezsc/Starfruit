import Foundation
import Security

struct Migration {
    private static let oldBundleId = "com.starfruit.macnative"
    private static let newBundleId = Bundle.main.bundleIdentifier ?? "com.bunnygamez.starfruit"
    private static let migratedKey = "migration_done_from_\(oldBundleId)_to_\(newBundleId)_v3"
    private static let credentialsKey = "migration_done_nexus_from_\(oldBundleId)_to_\(newBundleId)_v3"
    private static var reportURL: URL {
        supportRoot.appendingPathComponent("StarfruitNative/migration-report-v3.json")
    }
    private static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func migrateIfNeeded(force: Bool = false) -> LegacyMigrationReport {
        if !force, UserDefaults.standard.bool(forKey: migratedKey), let saved = lastReport { return saved }
        migrateUserDefaults()
        let dataMigration = LegacyDataMigration(applicationSupport: supportRoot,
            additionalApplicationSupportRoots: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")])
        var report = dataMigration.run()
        do {
            let preferences = LegacyDataMigration.mergingPreferences(
                current: UserDefaults.standard.persistentDomain(forName: newBundleId) ?? [:],
                older: [try dataMigration.desktopPreferences()])
            UserDefaults.standard.setPersistentDomain(preferences, forName: newBundleId)
        } catch { report.issues.append("Older desktop settings could not be read and were left unchanged: \(error.localizedDescription)") }
        let domain = UserDefaults.standard.persistentDomain(forName: newBundleId) ?? [:]
        let useWine = domain["useWine"] as? Bool ?? true
        let configuredPath = domain[useWine ? "wineSmapiDir" : "nativeSmapiDir"] as? String ?? ""
        if domain["onboarding.completed"] == nil, !configuredPath.isEmpty,
           report.importedProfiles + (report.retainedProfiles ?? 0) > 0 {
            UserDefaults.standard.set(true, forKey: "onboarding.completed")
        }
        if !UserDefaults.standard.bool(forKey: credentialsKey) {
            if migrateKeychain() { UserDefaults.standard.set(true, forKey: credentialsKey) }
            else { report.issues.append("Nexus login could not be copied from Keychain yet. Starfruit will retry next launch; the original login is unchanged.") }
        }
        UserDefaults.standard.set(report.completed, forKey: migratedKey)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: reportURL, options: .atomic) }
        return report
    }

    static var lastReport: LegacyMigrationReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(LegacyMigrationReport.self, from: data)
    }

    private static func migrateUserDefaults() {
        let older = [oldBundleId, "com.starfruit.native"].filter { $0 != newBundleId }.map {
            UserDefaults.standard.persistentDomain(forName: $0) ?? [:]
        }
        let current = LegacyDataMigration.mergingPreferences(
            current: UserDefaults.standard.persistentDomain(forName: newBundleId) ?? [:], older: older)
        UserDefaults.standard.setPersistentDomain(current, forName: newBundleId)
    }

    private static func migrateKeychain() -> Bool {
        let account = KeychainHelper.account
        let destination: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainHelper.service,
            kSecAttrAccount as String: account
        ]
        // Never replace a key the user has already saved in the new app.
        let destinationStatus = SecItemCopyMatching(destination as CFDictionary, nil)
        if destinationStatus == errSecSuccess { return true }
        guard destinationStatus == errSecItemNotFound else { return false }

        // The legacy Keychain service differs from the legacy bundle identifier.
        for service in ["com.starfruit.native", oldBundleId] where service != KeychainHelper.service {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = item as? Data else { return false }
            var add = destination
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            // Keep the source item available to the old app and to a rollback.
            return addStatus == errSecSuccess || addStatus == errSecDuplicateItem
        }
        for domain in [oldBundleId, "com.starfruit.native", newBundleId] {
            if let key = UserDefaults.standard.persistentDomain(forName: domain)?["nexus-api-key-fallback"] as? String, !key.isEmpty {
                var add = destination
                add[kSecValueData as String] = Data(key.utf8)
                let status = SecItemAdd(add as CFDictionary, nil)
                return status == errSecSuccess || status == errSecDuplicateItem
            }
        }
        return true
    }
}
