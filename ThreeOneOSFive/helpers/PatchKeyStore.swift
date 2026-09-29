import CryptoKit
import Foundation
import Security

enum PatchKeyStore {
    private static let service = "com.apple.mobile.MobileHouseArrest.patch-keys"
    private static let sessionService = "com.apple.mobile.MobileHouseArrest.session-storage"
    private static let sessionAccount = "runtime-content-key"
    private static let atRestMagic = Data("EXTSYS1".utf8)

    static func account(for summary: PatchPackageSummary) -> String {
        let fingerprint = summary.keyFingerprint.map { String(format: "%02x", $0) }.joined()
        return "\(summary.packageID.uuidString).\(fingerprint)"
    }

    static func store(_ contentKey: Data, for summary: PatchPackageSummary) throws {
        guard contentKey.count == 32,
              Data(SHA256.hash(data: contentKey)) == summary.keyFingerprint else {
            throw PatchPackageError.keychainFailed
        }
        let account = account(for: summary)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: contentKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PatchPackageError.keychainFailed
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
            throw PatchPackageError.keychainFailed
        }
    }

    static func load(for summary: PatchPackageSummary) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: summary),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              data.count == 32,
              Data(SHA256.hash(data: data)) == summary.keyFingerprint else {
            throw PatchPackageError.keychainFailed
        }
        return data
    }

    static func delete(for summary: PatchPackageSummary) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: summary)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PatchPackageError.keychainFailed
        }
    }

    static func establishSession(apiKey: String, deviceID: String) throws {
        let material = Data("EXTERNAL-SYSTEM|\(apiKey)|\(deviceID)".utf8)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data("patch-storage-v1".utf8),
            info: Data("runtime-patches".utf8),
            outputByteCount: 32
        )
        let derived = derivedKey.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: sessionAccount
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = derived
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw PatchPackageError.keychainFailed
        }
    }

    static func clearSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: sessionAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func sessionKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: sessionAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else {
            throw PatchPackageError.keychainFailed
        }
        return SymmetricKey(data: data)
    }

    static func encryptAtRest(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: sessionKey())
        guard let combined = sealed.combined else { throw PatchPackageError.keychainFailed }
        return atRestMagic + combined
    }

    static func decryptAtRest(_ data: Data) throws -> Data {
        guard data.starts(with: atRestMagic) else { return data }
        let sealed = try AES.GCM.SealedBox(combined: Data(data.dropFirst(atRestMagic.count)))
        return try AES.GCM.open(sealed, using: sessionKey())
    }

    static func deleteAll() {
        for serviceName in [service, sessionService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
