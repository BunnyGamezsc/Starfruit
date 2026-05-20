import Foundation
import Security

struct KeychainHelper {
    static let service = "com.starfruit.native"
    static let account = "nexus-api-key"

    private static func log(_ message: String) {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("StarfruitNative", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        let logURL = appSupport.appendingPathComponent("deeplinks.log")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let logLine = "[\(timestamp)] [Keychain] \(message)\n"
        if let data = logLine.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                try? data.write(to: logURL)
            }
        }
        print("[Keychain] \(message)")
    }

    static func save(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)
        log("SecItemDelete status: \(deleteStatus)")

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        log("SecItemAdd status: \(addStatus)")
        if addStatus != errSecSuccess {
            if let errorMsg = SecCopyErrorMessageString(addStatus, nil) {
                log("SecItemAdd error description: \(errorMsg)")
            }
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        log("SecItemCopyMatching status: \(status)")
        if status != errSecSuccess {
            if let errorMsg = SecCopyErrorMessageString(status, nil) {
                log("SecItemCopyMatching error description: \(errorMsg)")
            }
        }

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        return nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        log("SecItemDelete status: \(status)")
    }
}


