import CryptoKit
import Foundation

enum PatchKeyStore {
    private static let atRestMagic = Data("EXTSYS2".utf8)
    private static var sessionKeyStorage: SymmetricKey?
    private static var contentKeys: [String: Data] = [:]

    static func account(for summary: PatchPackageSummary) -> String {
        let fingerprint = summary.keyFingerprint.map { String(format: "%02x", $0) }.joined()
        return "\(summary.packageID.uuidString).\(fingerprint)"
    }

    static func store(_ contentKey: Data, for summary: PatchPackageSummary) throws {
        guard contentKey.count == 32,
              Data(SHA256.hash(data: contentKey)) == summary.keyFingerprint else {
            throw PatchPackageError.keychainFailed
        }
        contentKeys[account(for: summary)] = contentKey
    }

    static func load(for summary: PatchPackageSummary) throws -> Data? {
        contentKeys[account(for: summary)]
    }

    static func delete(for summary: PatchPackageSummary) throws {
        contentKeys.removeValue(forKey: account(for: summary))
    }

    /// A new session key is created after each successful server authorization.
    /// It is never persisted, so backups and Keychain migration cannot restore it.
    static func establishSession(apiKey: String, deviceID: String) throws {
        let sessionSalt = SymmetricKey(size: .bits256)
        let salt = sessionSalt.withUnsafeBytes { Data($0) }
        let material = Data("EXTERNAL-SYSTEM|\(apiKey)|\(deviceID)".utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: salt,
            info: Data("runtime-patches-session-v2".utf8),
            outputByteCount: 32
        )
        sessionKeyStorage = key
        contentKeys.removeAll(keepingCapacity: false)
    }

    static func clearSession() {
        sessionKeyStorage = nil
        contentKeys.removeAll(keepingCapacity: false)
    }

    static func hasSession() -> Bool {
        sessionKeyStorage != nil
    }

    private static func derivedPatchKey(packageID: UUID, schemaVersion: Int) throws -> SymmetricKey {
        guard let sessionKey = sessionKeyStorage else {
            throw PatchPackageError.keychainFailed
        }
        var info = Data("patch-content-v2|".utf8)
        info.append(contentsOf: packageID.uuidString.utf8)
        info.append(0)
        info.append(contentsOf: Data(String(schemaVersion).utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            salt: Data("per-patch-version".utf8),
            info: info,
            outputByteCount: 32
        )
    }

    static func encryptAtRest(_ data: Data) throws -> Data {
        let summary = try PatchPackageCodec.inspect(data)
        let key = try derivedPatchKey(packageID: summary.packageID, schemaVersion: summary.schemaVersion)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw PatchPackageError.keychainFailed }
        var output = atRestMagic
        output.append(contentsOf: summary.packageID.uuidString.data(using: .utf8)!)
        output.append(0)
        output.append(contentsOf: Data(String(summary.schemaVersion).utf8))
        output.append(0)
        output.append(contentsOf: combined)
        return output
    }

    static func decryptAtRest(_ data: Data) throws -> Data {
        guard data.starts(with: atRestMagic) else { return data }
        let header = Data(data.dropFirst(atRestMagic.count))
        guard let firstSeparator = header.firstIndex(of: 0),
              let packageID = UUID(uuidString: String(decoding: header[..<firstSeparator], as: UTF8.self)) else {
            throw PatchPackageError.invalidProject
        }
        let versionStart = header.index(after: firstSeparator)
        guard let secondSeparator = header[versionStart...].firstIndex(of: 0),
              let schemaVersion = Int(String(decoding: header[versionStart..<secondSeparator], as: UTF8.self)) else {
            throw PatchPackageError.invalidProject
        }
        let combined = Data(header[header.index(after: secondSeparator)...])
        let sealed = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(sealed, using: derivedPatchKey(packageID: packageID, schemaVersion: schemaVersion))
        let summary = try PatchPackageCodec.inspect(plaintext)
        guard summary.packageID == packageID, summary.schemaVersion == schemaVersion else {
            throw PatchPackageError.invalidProject
        }
        return plaintext
    }

    static func deleteAll() {
        clearSession()
    }
}
