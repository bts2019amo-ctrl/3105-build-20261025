import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    static let baseURL = URL(string: "https://systemstore-9su6ubez.manus.space")!
    static let syncToken = "3105-sync-v1-9f2d7a4c"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}

private struct RemoteFeedEnvelope: Decodable { let result: RemoteFeedResult }
private struct RemoteFeedResult: Decodable { let data: RemoteFeedData }
private struct RemoteFeedData: Decodable { let json: RemoteFeed }
private struct RemoteFeed: Decodable { let version: Int64; let patches: [RemoteFeedPatch] }
private struct RemoteFeedPatch: Decodable {
    let id: Int; let name: String; let category: String; let feature: String
    let fileName: String; let fileKey: String; let fileUrl: String; let mimeType: String
    let fileSize: Int; let version: Int; let changelog: String?; let checksumSha256: String
    let iconUrl: String?; let password: String?; let updatedAt: Int64
}

enum RemoteSyncState: Equatable { case idle, syncing, online, offline }

struct PatchStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var messageArgument: String?
    init(titleKey: String, messageKey: String, messageArgument: String? = nil) {
        self.titleKey = titleKey; self.messageKey = messageKey; self.messageArgument = messageArgument
    }
    func message(language: AppLanguage) -> String {
        if let messageArgument { return language.text(messageKey, messageArgument) }
        return language.text(messageKey)
    }
}

@MainActor
final class PatchProjectStore: ObservableObject {
    @Published private(set) var items: [PatchLibraryItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var remoteSyncState: RemoteSyncState = .idle
    @Published private(set) var lastRemoteSyncAt: Date?
    @Published private(set) var lastRemoteSyncError: String?
    @Published var passwordRequest: PatchPasswordRequest?
    @Published var alert: PatchStoreAlert?
    @Published var unlockErrorKey: String?

    private struct PendingUnlock {
        let data: Data; let summary: PatchPackageSummary; let existingURL: URL?
        let origin: PatchPackageOrigin?; let remoteID: Int?; let remoteVersion: Int64?
        let remoteCategory: PatchGameCategory?; let remoteFeature: PatchFeatureCategory?
    }

    private var pendingUnlock: PendingUnlock?
    private var remoteSyncTask: Task<Void, Never>?
    private var remoteSyncInFlight = false
    private var isActivated = false

    init(autoLoad: Bool = true) {
        guard autoLoad else { return }
        activate()
    }

    func activate() {
        guard IOSKeySession.runtimeAuthorized, !isActivated else { return }
        isActivated = true
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let loadedItems = PatchProjectLibrary.load()
            await self?.finishInitialLoad(loadedItems)
        }
    }

    func deactivateAndClear() {
        isActivated = false
        stopRemoteSync()
        try? PatchProjectLibrary.resetAll()
        items = []; isBusy = false; remoteSyncState = .idle
        lastRemoteSyncAt = nil; lastRemoteSyncError = nil
        passwordRequest = nil; alert = nil; unlockErrorKey = nil
    }

    func reload() { items = PatchProjectLibrary.load() }

    func startRemoteSync() {
        guard IOSKeySession.runtimeAuthorized, isActivated, remoteSyncTask == nil else { return }
        remoteSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronizeRemoteFeed()
                try? await Task.sleep(nanoseconds: RemotePatchConfiguration.pollIntervalNanoseconds)
            }
        }
    }

    func stopRemoteSync() {
        remoteSyncTask?.cancel()
        remoteSyncTask = nil
    }

    func syncNow() {
        guard IOSKeySession.runtimeAuthorized else { return }
        Task { await synchronizeRemoteFeed() }
    }

    private static func inferredGameCategory(name: String, fileName: String) -> PatchGameCategory {
        let value = "\(name) \(fileName)".lowercased()
        return value.contains("max") || value.contains("freefiremax") ? .max : .normal
    }

    private static func inferredFeatureCategory(name: String, fileName: String) -> PatchFeatureCategory {
        let value = "\(name) \(fileName)".lowercased()
        if value.contains("external") || value.contains("aimbot") || value.contains("esp") { return .external }
        if value.contains("skin") { return .skin }
        if value.contains("avatar") { return .avatar }
        if value.contains("hologram") || value.contains("holo") { return .hologram }
        return .cache
    }

    private func synchronizeRemoteFeed() async {
        guard IOSKeySession.runtimeAuthorized, isActivated, !remoteSyncInFlight else { return }
        remoteSyncInFlight = true
        defer { remoteSyncInFlight = false }
        remoteSyncState = .syncing
        do {
            var components = URLComponents(
                url: RemotePatchConfiguration.baseURL.appendingPathComponent("api/trpc/patches.feed"),
                resolvingAgainstBaseURL: false
            )!
            let payload: [String: Any] = [
                "json": [
                    "syncToken": RemotePatchConfiguration.syncToken,
                    "installationFingerprint": IOSKeySession.installationFingerprint
                ]
            ]
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            components.queryItems = [URLQueryItem(name: "input", value: String(data: payloadData, encoding: .utf8))]
            let networkConfiguration = URLSessionConfiguration.default
            networkConfiguration.waitsForConnectivity = true
            networkConfiguration.timeoutIntervalForRequest = 45
            networkConfiguration.timeoutIntervalForResource = 120
            networkConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let networkSession = URLSession(configuration: networkConfiguration)
            var feedRequest = URLRequest(url: components.url!)
            feedRequest.timeoutInterval = 30
            feedRequest.cachePolicy = .reloadIgnoringLocalCacheData
            feedRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            feedRequest.setValue("3105-iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await Self.fetchWithRetry(feedRequest, session: networkSession)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else {
                let body = String(data: data.prefix(512), encoding: .utf8) ?? "empty response"
                throw NSError(domain: "RemotePatchFeed", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode): \(body)"])
            }
            let envelope = try JSONDecoder().decode(RemoteFeedEnvelope.self, from: data)
            let feed = envelope.result.data.json
            await sendRemoteHeartbeat()
            var reservedPackageIDs = Set(items.map(\.id))
            var claimedPackageIDs = Set<UUID>()
            var importedCount = 0
            var skippedCount = 0
            for patch in feed.patches {
                await Task.yield()
                do {
                    let mappedID = PatchProjectLibrary.remotePackageID(for: patch.id)
                    let hasCurrentPackage = mappedID.map { id in items.contains(where: { $0.id == id }) } ?? false
                    let category = PatchGameCategory(rawValue: patch.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                        ?? Self.inferredGameCategory(name: patch.name, fileName: patch.fileName)
                    let normalizedPatchName = patch.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let feature = normalizedPatchName.caseInsensitiveCompare("External") == .orderedSame
                        ? PatchFeatureCategory.external
                        : (PatchFeatureCategory(rawValue: patch.feature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                            ?? Self.inferredFeatureCategory(name: patch.name, fileName: patch.fileName))
                    guard let url = Self.remoteURL(for: patch.fileUrl) else { continue }
                    if hasCurrentPackage && patch.updatedAt <= PatchProjectLibrary.remoteVersion(for: patch.id) {
                        if let mappedID {
                            PatchProjectLibrary.setCategory(category, for: mappedID)
                            PatchProjectLibrary.setFeatureCategory(feature, for: mappedID)
                            PatchProjectLibrary.setFeatureIdentifier(patch.feature, for: mappedID)
                        }
                        continue
                    }
                    var packageRequest = URLRequest(url: url)
                    packageRequest.timeoutInterval = 30
                    packageRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    packageRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    packageRequest.setValue("3105-iOS", forHTTPHeaderField: "User-Agent")
                    var (packageData, packageResponse) = try await Self.fetchWithRetry(packageRequest, session: networkSession)
                    let downloadedData = packageData
                    let checksum = await Task.detached(priority: .utility) { Self.sha256Hex(downloadedData) }.value
                    guard let packageResponse = packageResponse as? HTTPURLResponse,
                          (200..<300).contains(packageResponse.statusCode),
                          checksum == patch.checksumSha256.lowercased() else { continue }
                    let inspectedData = packageData
                    var summary = try await Task.detached(priority: .utility) { try PatchPackageCodec.inspect(inspectedData) }.value
                    var existingURL = items.first(where: { $0.id == mappedID })?.packageURL
                    if !summary.isPasswordProtected,
                       (mappedID == nil || (mappedID != nil && claimedPackageIDs.contains(mappedID!)))
                        && reservedPackageIDs.contains(summary.packageID) {
                        let dataToDecode = packageData
                        let decoded = try await Task.detached(priority: .utility) { try PatchPackageCodec.decode(dataToDecode, password: nil) }.value
                        let newID = UUID()
                        let dataToReidentify = packageData
                        packageData = try await Task.detached(priority: .utility) {
                            try PatchPackageCodec.reidentifyPublicPackage(dataToReidentify, decoded: decoded, newID: newID)
                        }.value
                        let reidentifiedData = packageData
                        summary = try await Task.detached(priority: .utility) { try PatchPackageCodec.inspect(reidentifiedData) }.value
                        existingURL = nil
                    }
                    let dataToPersist = packageData
                    let summaryToPersist = summary
                    let urlToPersist = existingURL
                    let pendingUnlock: PendingUnlock?
                    do {
                        pendingUnlock = try await Task.detached(priority: .utility) {
                            try Self.persistImportedPackage(
                                data: dataToPersist, summary: summaryToPersist, existingURL: urlToPersist,
                                password: patch.password, category: category, feature: feature,
                                remoteID: patch.id, remoteVersion: patch.updatedAt, remoteName: patch.name
                            )
                        }.value
                    } catch {
                        guard summaryToPersist.isPasswordProtected else { throw error }
                        pendingUnlock = try await Task.detached(priority: .utility) {
                            try Self.persistImportedPackage(
                                data: dataToPersist, summary: summaryToPersist, existingURL: urlToPersist,
                                password: nil, category: category, feature: feature,
                                remoteID: patch.id, remoteVersion: patch.updatedAt, remoteName: patch.name
                            )
                        }.value
                    }
                    if pendingUnlock != nil {
                        let dataToSave = packageData
                        let urlToSave = existingURL
                        let summaryToSave = summary
                        try await Task.detached(priority: .utility) {
                            _ = try PatchProjectLibrary.save(data: dataToSave, projectName: patch.name, existingURL: urlToSave)
                            PatchProjectLibrary.setCategory(category, for: summaryToSave.packageID)
                            PatchProjectLibrary.setFeatureCategory(feature, for: summaryToSave.packageID)
                            PatchProjectLibrary.setFeatureIdentifier(patch.feature, for: summaryToSave.packageID)
                        }.value
                    }
                    PatchProjectLibrary.setRemotePackageID(summary.packageID, for: patch.id)
                    PatchProjectLibrary.setRemoteVersion(patch.updatedAt, for: patch.id)
                    PatchProjectLibrary.setDisplayName(patch.name, for: summary.packageID)
                    PatchProjectLibrary.setFeatureIdentifier(patch.feature, for: summary.packageID)
                    PatchProjectLibrary.setRemoteIconURL(patch.iconUrl, for: summary.packageID)
                    PatchProjectLibrary.setRemoteMetadata(version: patch.version, changelog: patch.changelog, checksum: patch.checksumSha256, for: summary.packageID)
                    reservedPackageIDs.insert(summary.packageID)
                    claimedPackageIDs.insert(summary.packageID)
                    importedCount += 1
                } catch {
                    skippedCount += 1
                    continue
                }
            }
            PatchProjectLibrary.removeRemotePackagesNotInFeed(remoteIDs: Set(feed.patches.map(\.id)))
            items = await Task.detached(priority: .utility) { PatchProjectLibrary.load() }.value
            remoteSyncState = .online
            lastRemoteSyncAt = Date()
            lastRemoteSyncError = skippedCount == 0 ? nil : "Feed: \(feed.patches.count); importados \(importedCount); ignorados \(skippedCount)."
        } catch {
            remoteSyncState = .offline
            lastRemoteSyncError = error.localizedDescription
        }
    }

    private static func remoteURL(for value: String) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: RemotePatchConfiguration.baseURL)?.absoluteURL
    }

    private static func fetchWithRetry(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await session.data(for: request) }
            catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func sendRemoteHeartbeat() async {
        guard IOSKeySession.runtimeAuthorized else { return }
        guard let url = URL(string: "api/trpc/patches.heartbeat", relativeTo: RemotePatchConfiguration.baseURL)?.absoluteURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["json": [
            "syncToken": RemotePatchConfiguration.syncToken,
            "installationFingerprint": IOSKeySession.installationFingerprint,
            "model": UIDevice.current.model,
            "osVersion": UIDevice.current.systemVersion,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        ]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func persistImportedPackage(
        data: Data, summary: PatchPackageSummary, existingURL: URL?, password: String?,
        category: PatchGameCategory, feature: PatchFeatureCategory,
        remoteID: Int, remoteVersion: Int64, remoteName: String
    ) throws -> PendingUnlock? {
        let decoded: DecodedPatchPackage
        if let password, !password.isEmpty {
            decoded = try PatchPackageCodec.decode(data, password: password)
        } else if summary.isPasswordProtected {
            _ = try PatchProjectLibrary.save(data: data, projectName: remoteName, existingURL: existingURL)
            PatchProjectLibrary.setCategory(category, for: summary.packageID)
            PatchProjectLibrary.setFeatureCategory(feature, for: summary.packageID)
            return PendingUnlock(data: data, summary: summary, existingURL: existingURL, origin: nil,
                remoteID: remoteID, remoteVersion: remoteVersion, remoteCategory: category, remoteFeature: feature)
        } else {
            decoded = try PatchPackageCodec.decode(data, password: nil)
        }
        try PatchKeyStore.store(decoded.contentKey, for: summary)
        try PatchProjectLibrary.installImportedPackage(data: data, decoded: decoded, summary: summary, existingURL: existingURL, origin: nil)
        PatchProjectLibrary.setCategory(category, for: summary.packageID)
        PatchProjectLibrary.setFeatureCategory(feature, for: summary.packageID)
        return nil
    }

    @MainActor
    private func finishInitialLoad(_ loadedItems: [PatchLibraryItem]) {
        items = loadedItems
        isBusy = false
        startRemoteSync()
    }

    func applyInline(_ item: PatchLibraryItem) {
        guard !isBusy else { return }
        guard let project = item.project else {
            requestUnlock(for: item)
            return
        }
        guard DevicePatchService.latestReceipt(projectID: item.id) == nil else {
            alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.error.already_applied", messageArgument: "Este patch já está aplicado.")
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let synchronized = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item) : project
                _ = try DevicePatchService.apply(project: synchronized)
                await self?.finishInlineApply(success: true)
            } catch let error as PatchPackageError {
                await self?.failOperationReadable(error)
            } catch {
                await self?.failOperationReadable(.applyFailed)
            }
        }
    }

    func restoreInline(_ item: PatchLibraryItem) {
        guard !isBusy, let receipt = DevicePatchService.latestReceipt(projectID: item.id) else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: true)
                await self?.finishInlineRestore(success: true)
            } catch let error as PatchPackageError {
                await self?.failOperationReadable(error)
            } catch {
                await self?.failOperationReadable(.restoreFailed)
            }
        }
    }

    private func finishInlineApply(success: Bool) {
        reload(); isBusy = false
        if success {
            alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message", messageArgument: "Patch aplicado com sucesso.")
        }
    }

    private func finishInlineRestore(success: Bool) {
        reload(); isBusy = false
        if success {
            alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message", messageArgument: "Patch restaurado (original).")
        }
    }

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            _ = try PatchProjectLibrary.readPackage(at: item.packageURL)
            passwordRequest = PatchPasswordRequest(summary: item.summary, origin: item.origin)
        } catch {
            alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.unsupported_format", messageArgument: "Não foi possível abrir o pacote.")
        }
    }

    func unlock(password: String) {
        guard let request = passwordRequest, !isBusy else { return }
        isBusy = true
        unlockErrorKey = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let packageID = request.summary.packageID
                guard let item = await MainActor.run(body: { self?.items.first(where: { $0.id == packageID }) }) else {
                    throw PatchPackageError.invalidProject
                }
                let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
                let decoded = try PatchPackageCodec.decode(data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: request.summary)
                try PatchProjectLibrary.installImportedPackage(data: data, decoded: decoded, summary: request.summary, existingURL: item.packageURL, origin: item.origin)
                await MainActor.run {
                    self?.passwordRequest = nil
                    self?.reload()
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message", messageArgument: "Desbloqueado. Toque de novo para aplicar.")
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.unlockErrorKey = "patch.error.wrong_password"
                }
            }
        }
    }

    func cancelUnlock() { passwordRequest = nil; unlockErrorKey = nil; pendingUnlock = nil }
    func clearUnlockError() { unlockErrorKey = nil }

    @MainActor
    private func failOperationReadable(_ error: PatchPackageError) {
        isBusy = false
        let pt: String
        switch error {
        case .targetAppUnavailable(let bundle):
            pt = "App alvo não encontrado (\(bundle)). Abra o Free Fire e confirme o exploit."
        case .applyFailed:
            pt = "Falha ao aplicar. Free Fire instalado e exploit ativo?"
        case .restoreFailed:
            pt = "Falha ao restaurar o patch."
        default:
            pt = error.errorDescription ?? error.localizationKey
        }
        alert = PatchStoreAlert(titleKey: "common.failed", messageKey: error.localizationKey, messageArgument: pt)
    }

    private func failOperation(_ error: PatchPackageError) { isBusy = false; present(error) }
    private func failUnlock(_ error: PatchPackageError) {
        isBusy = false
        if case .invalidPasswordOrCorruptedPackage = error { unlockErrorKey = "patch.error.wrong_password" }
        else { unlockErrorKey = error.localizationKey }
    }
    private func present(_ error: PatchPackageError) {
        alert = PatchStoreAlert(titleKey: "common.failed", messageKey: error.localizationKey, messageArgument: error.localizationArgument)
    }
}
