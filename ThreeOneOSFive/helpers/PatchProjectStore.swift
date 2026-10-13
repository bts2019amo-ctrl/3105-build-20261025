import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    static let baseURL = URL(string: "https://patchremote-guxthetm.manus.space")!
    static let syncToken = "3105-sync-v1-9f2d7a4c"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}

private struct RemoteFeedEnvelope: Decodable {
    let result: RemoteFeedResult
}

private struct RemoteFeedResult: Decodable {
    let data: RemoteFeedData
}

private struct RemoteFeedData: Decodable {
    let json: RemoteFeed
}

private struct RemoteFeed: Decodable {
    let version: Int64
    let patches: [RemoteFeedPatch]
}

private struct RemoteFeedPatch: Decodable {
    let id: Int
    let name: String
    let category: String
    let feature: String
    let fileName: String
    let fileKey: String
    let fileUrl: String
    let mimeType: String
    let fileSize: Int
    let version: Int
    let changelog: String?
    let checksumSha256: String
    let iconUrl: String?
    let updatedAt: Int64
}

enum RemoteSyncState: Equatable {
    case idle
    case syncing
    case online
    case offline
}

struct PatchStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var messageArgument: String?

    init(titleKey: String, messageKey: String, messageArgument: String? = nil) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.messageArgument = messageArgument
    }

    func message(language: AppLanguage) -> String {
        if let messageArgument {
            return language.text(messageKey, messageArgument)
        }
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
        let data: Data
        let summary: PatchPackageSummary
        let existingURL: URL?
        let origin: PatchPackageOrigin?
        let remoteID: Int?
        let remoteVersion: Int64?
        let remoteCategory: PatchGameCategory?
        let remoteFeature: PatchFeatureCategory?
    }

    private var pendingUnlock: PendingUnlock?
    private var remoteSyncTask: Task<Void, Never>?
    private var isActivated = false

    init(autoLoad: Bool = true) {
        guard autoLoad else { return }
        activate()
    }

    func activate() {
        guard !isActivated else { return }
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
        items = []
        isBusy = false
        remoteSyncState = .idle
        lastRemoteSyncAt = nil
        lastRemoteSyncError = nil
        passwordRequest = nil
        alert = nil
        unlockErrorKey = nil
    }

    func reload() {
        items = PatchProjectLibrary.load()
    }

    func startRemoteSync() {
        guard isActivated, remoteSyncTask == nil else { return }
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
        guard !isBusy else { return }
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
            components.queryItems = [URLQueryItem(
                name: "input",
                value: String(data: payloadData, encoding: .utf8)
            )]
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
            let (data, response) = try await Self.fetchWithRetry(
                feedRequest,
                session: networkSession
            )
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
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
                    let category = PatchGameCategory(rawValue: patch.category)
                        ?? Self.inferredGameCategory(name: patch.name, fileName: patch.fileName)
                    let normalizedPatchName = patch.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let feature = normalizedPatchName.caseInsensitiveCompare("External") == .orderedSame
                        ? .external
                        : (PatchFeatureCategory(rawValue: patch.feature)
                            ?? Self.inferredFeatureCategory(name: patch.name, fileName: patch.fileName))
                    guard let url = Self.remoteURL(for: patch.fileUrl) else { continue }
                    if hasCurrentPackage && patch.updatedAt <= PatchProjectLibrary.remoteVersion(for: patch.id) {
                        if let mappedID {
                            PatchProjectLibrary.setCategory(category, for: mappedID)
                            PatchProjectLibrary.setFeatureCategory(feature, for: mappedID)
                        }
                        continue
                    }
                    var packageRequest = URLRequest(url: url)
                    packageRequest.timeoutInterval = 30
                    packageRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    packageRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                    packageRequest.setValue("3105-iOS", forHTTPHeaderField: "User-Agent")
                    var (packageData, packageResponse) = try await Self.fetchWithRetry(
                        packageRequest,
                        session: networkSession
                    )
                    let checksum = await Task.detached(priority: .utility) {
                        Self.sha256Hex(packageData)
                    }.value
                    guard let packageResponse = packageResponse as? HTTPURLResponse,
                          (200..<300).contains(packageResponse.statusCode),
                          checksum == patch.checksumSha256.lowercased() else { continue }
                    var summary = try await Task.detached(priority: .utility) {
                        try PatchPackageCodec.inspect(packageData)
                    }.value
                    var existingURL = items.first(where: { $0.id == mappedID })?.packageURL
                    if (mappedID == nil || (mappedID != nil && claimedPackageIDs.contains(mappedID!)))
                        && reservedPackageIDs.contains(summary.packageID) {
                        let decoded = try await Task.detached(priority: .utility) {
                            try PatchPackageCodec.decode(packageData, password: nil)
                        }.value
                        let newID = UUID()
                        packageData = try await Task.detached(priority: .utility) {
                            try PatchPackageCodec.reidentifyPublicPackage(
                                packageData,
                                decoded: decoded,
                                newID: newID
                            )
                        }.value
                        summary = try await Task.detached(priority: .utility) {
                            try PatchPackageCodec.inspect(packageData)
                        }.value
                        existingURL = nil
                    }
                    let pendingUnlock = try await Task.detached(priority: .utility) {
                        try Self.persistImportedPackage(
                            data: packageData,
                            summary: summary,
                            existingURL: existingURL,
                            category: category,
                            feature: feature,
                            remoteID: patch.id,
                            remoteVersion: patch.updatedAt,
                            remoteName: patch.name
                        )
                    }.value
                    if pendingUnlock != nil {
                        try await Task.detached(priority: .utility) {
                            _ = try PatchProjectLibrary.save(
                                data: packageData,
                                projectName: patch.name,
                                existingURL: existingURL
                            )
                            PatchProjectLibrary.setCategory(category, for: summary.packageID)
                            PatchProjectLibrary.setFeatureCategory(feature, for: summary.packageID)
                        }.value
                    }
                    PatchProjectLibrary.setRemotePackageID(summary.packageID, for: patch.id)
                    PatchProjectLibrary.setRemoteVersion(patch.updatedAt, for: patch.id)
                    PatchProjectLibrary.setDisplayName(patch.name, for: summary.packageID)
                    PatchProjectLibrary.setRemoteIconURL(patch.iconUrl, for: summary.packageID)
                    PatchProjectLibrary.setRemoteMetadata(
                        version: patch.version,
                        changelog: patch.changelog,
                        checksum: patch.checksumSha256,
                        for: summary.packageID
                    )
                    reservedPackageIDs.insert(summary.packageID)
                    claimedPackageIDs.insert(summary.packageID)
                    importedCount += 1
                } catch {
                    skippedCount += 1
                    // One malformed or incompatible remote package must not hide the rest.
                    continue
                }
            }
            await Task.detached(priority: .utility) {
                PatchProjectLibrary.removeRemotePackagesNotInFeed(
                    remoteIDs: Set(feed.patches.map(\.id))
                )
            }.value
            items = await Task.detached(priority: .utility) {
                PatchProjectLibrary.load()
            }.value
            remoteSyncState = .online
            lastRemoteSyncAt = Date()
            lastRemoteSyncError = skippedCount == 0
                ? nil
                : "Feed recebido: \(feed.patches.count) patches; \(importedCount) importados e \(skippedCount) ignorados."
        } catch {
            remoteSyncState = .offline
            lastRemoteSyncError = error.localizedDescription
        }
    }

    private static func remoteURL(for value: String) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        return URL(string: value, relativeTo: RemotePatchConfiguration.baseURL)?.absoluteURL
    }

    private static func fetchWithRetry(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
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
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        ]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let ephemeralSession = URLSession(configuration: .ephemeral)
        _ = try? await ephemeralSession.data(for: request)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func finishInitialLoad(_ loadedItems: [PatchLibraryItem]) {
        items = loadedItems
        isBusy = false
    }

    func create(project: PatchProject, password: String?) {
        runOperation(successMessageKey: "patch.created_message") {
            let encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
            let summary = try PatchPackageCodec.inspect(encoded.data)
            let workspace = try PatchWorkspaceService.createWorkspace(for: project)
            var savedURL: URL?
            do {
                if summary.isPasswordProtected {
                    try PatchKeyStore.store(encoded.contentKey, for: summary)
                }
                savedURL = try PatchProjectLibrary.save(
                    data: encoded.data,
                    projectName: project.name
                )
                try PatchProjectLibrary.markAsAuthorCopy(packageID: project.id)
                PatchProjectLibrary.setCategory(
                    PatchProjectLibrary.selectedCategory,
                    for: project.id
                )
                PatchProjectLibrary.setFeatureCategory(
                    PatchProjectLibrary.selectedFeatureCategory,
                    for: project.id
                )
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                if let savedURL {
                    try? FileManager.default.removeItem(at: savedURL)
                }
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
        }
    }

    func update(project: PatchProject) {
        guard let item = items.first(where: { $0.id == project.id }),
              let contentKey = item.contentKey else {
            present(.invalidProject)
            return
        }
        runOperation(successMessageKey: "patch.updated_message") {
            let original = try PatchProjectLibrary.readPackage(at: item.packageURL)
            let updated = try PatchPackageCodec.update(
                original,
                project: project,
                contentKey: contentKey,
                schemaVersion: PatchPackageCodec.latestSchemaVersion
            )
            _ = try PatchProjectLibrary.save(
                data: updated,
                projectName: project.name,
                existingURL: item.packageURL
            )
        }
    }

    func importPackage(at sourceURL: URL) {
        guard !isBusy else { return }
        isBusy = true
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try PatchProjectLibrary.readPackage(at: sourceURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.unsupportedFormat)
            }
        }
    }

    @discardableResult
    func importPackage(
        data: Data,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil
    ) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    password: password,
                    origin: origin
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.unsupportedFormat)
            }
        }
        return true
    }

    func presentImportError(_ error: PatchPackageError) {
        present(error)
    }

    func importPackage(from source: PatchImportSource) {
        switch source {
        case .file(let url):
            importPackage(at: url)
        case .remote(let url):
            importPackage(fromRemoteURL: url)
        case .invalid:
            present(.invalidImportLink)
        }
    }

    private func importPackage(fromRemoteURL remoteURL: URL) {
        guard !isBusy,
              PatchImportRoute.validatedRemoteURL(remoteURL) != nil else {
            if !isBusy { present(.invalidImportLink) }
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }

                let (temporaryURL, response) = try await session.download(from: remoteURL)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let finalURL = response.url,
                      PatchImportRoute.validatedRemoteURL(finalURL) != nil else {
                    throw PatchPackageError.remoteImportFailed
                }

                let data = try PatchProjectLibrary.readPackage(at: temporaryURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.remoteImportFailed)
            }
        }
    }

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
            pendingUnlock = PendingUnlock(
                data: data,
                summary: item.summary,
                existingURL: item.packageURL,
                origin: item.origin,
                remoteID: nil,
                remoteVersion: nil,
                remoteCategory: nil,
                remoteFeature: nil
            )
            passwordRequest = PatchPasswordRequest(
                summary: item.summary,
                origin: item.origin
            )
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.unsupportedFormat)
        }
    }

    func unlock(password: String) {
        guard let pending = pendingUnlock, !isBusy else { return }
        isBusy = true
        unlockErrorKey = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try PatchPackageCodec.decode(pending.data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: pending.summary)
                do {
                    try PatchProjectLibrary.installImportedPackage(
                        data: pending.data,
                        decoded: decoded,
                        summary: pending.summary,
                        existingURL: pending.existingURL,
                        origin: pending.origin
                    )
                    if let category = pending.remoteCategory {
                        PatchProjectLibrary.setCategory(category, for: pending.summary.packageID)
                    } else {
                        PatchProjectLibrary.setCategory(PatchProjectLibrary.selectedCategory, for: pending.summary.packageID)
                    }
                    if let feature = pending.remoteFeature {
                        PatchProjectLibrary.setFeatureCategory(feature, for: pending.summary.packageID)
                    } else {
                        PatchProjectLibrary.setFeatureCategory(PatchProjectLibrary.selectedFeatureCategory, for: pending.summary.packageID)
                    }
                    if let remoteID = pending.remoteID {
                        PatchProjectLibrary.setRemotePackageID(pending.summary.packageID, for: remoteID)
                        PatchProjectLibrary.setRemoteVersion(pending.remoteVersion ?? 0, for: remoteID)
                    }
                } catch {
                    try? PatchKeyStore.delete(for: pending.summary)
                    throw error
                }
                await self?.clearPendingUnlock()
                await self?.finishOperation(successMessageKey: "patch.unlocked_message")
            } catch let error as PatchPackageError {
                await self?.failUnlock(error)
            } catch {
                await self?.failUnlock(.invalidPasswordOrCorruptedPackage)
            }
        }
    }

    func cancelUnlock() {
        clearPendingUnlock()
        isBusy = false
    }

    func clearUnlockError() {
        unlockErrorKey = nil
    }

    func delete(_ item: PatchLibraryItem) {
        do {
            try PatchProjectLibrary.delete(item)
            reload()
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.invalidProject)
        }
    }

    func synchronizeWorkspace(projectID: UUID, reportsSuccess: Bool = false) {
        guard let item = items.first(where: { $0.id == projectID }),
              item.summary.schemaVersion >= 2,
              !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                await self?.finishWorkspaceSynchronization(reportsSuccess: reportsSuccess)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    func applyInline(_ item: PatchLibraryItem) {
        guard !isBusy else { return }
        guard let project = item.project else {
            requestUnlock(for: item)
            return
        }
        guard DevicePatchService.latestReceipt(projectID: item.id) == nil else {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.error.already_applied"
            )
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let synchronized = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : project
                _ = try DevicePatchService.apply(project: synchronized)
                await self?.finishInlineApply(success: true)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.applyFailed)
            }
        }
    }

    func restoreInline(_ item: PatchLibraryItem) {
        guard !isBusy,
              let receipt = DevicePatchService.latestReceipt(projectID: item.id) else {
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: true)
                await self?.finishInlineRestore(success: true)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.restoreFailed)
            }
        }
    }

    private func finishInlineRestore(success: Bool) {
        reload()
        isBusy = false
        if success {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.restored_message"
            )
        }
    }

    private func finishInlineApply(success: Bool) {
        reload()
        isBusy = false
        if success {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.applied_message"
            )
        }
    }

    private func finishWorkspaceSynchronization(reportsSuccess: Bool) {
        reload()
        isBusy = false
        if reportsSuccess {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.workspace_synced_message"
            )
        }
    }

    private func runOperation(
        successMessageKey: String,
        operation: @escaping () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try operation()
                await self?.finishOperation(successMessageKey: successMessageKey)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    private func requestPassword(pending: PendingUnlock) {
        pendingUnlock = pending
        passwordRequest = PatchPasswordRequest(
            summary: pending.summary,
            origin: pending.origin
        )
        isBusy = false
    }

    private func existingPackageURL(for packageID: UUID) -> URL? {
        items.first(where: { $0.id == packageID })?.packageURL
    }

    private nonisolated static func persistImportedPackage(
        data: Data,
        summary: PatchPackageSummary,
        existingURL: URL?,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil,
        category: PatchGameCategory? = nil,
        feature: PatchFeatureCategory? = nil,
        remoteID: Int? = nil,
        remoteVersion: Int64? = nil,
        remoteName: String? = nil
    ) throws -> PendingUnlock? {
        let assignedCategory = category ?? PatchProjectLibrary.selectedCategory
        let assignedFeature = feature ?? PatchProjectLibrary.selectedFeatureCategory
        if let key = try PatchKeyStore.load(for: summary) {
            let decoded = try PatchPackageCodec.decode(data, contentKey: key)
            try PatchProjectLibrary.installImportedPackage(
                data: data,
                decoded: decoded,
                summary: summary,
                existingURL: existingURL,
                origin: origin
            )
            PatchProjectLibrary.setCategory(assignedCategory, for: summary.packageID)
            PatchProjectLibrary.setFeatureCategory(assignedFeature, for: summary.packageID)
            if let remoteID {
                PatchProjectLibrary.setRemotePackageID(summary.packageID, for: remoteID)
                PatchProjectLibrary.setRemoteVersion(remoteVersion ?? 0, for: remoteID)
                if let remoteName { PatchProjectLibrary.setDisplayName(remoteName, for: summary.packageID) }
            }
            return nil
        }
        if summary.isPasswordProtected {
            guard let password else {
                return PendingUnlock(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin,
                    remoteID: remoteID,
                    remoteVersion: remoteVersion,
                    remoteCategory: category,
                    remoteFeature: feature
                )
            }
            let decoded = try PatchPackageCodec.decode(data, password: password)
            try PatchKeyStore.store(decoded.contentKey, for: summary)
            do {
                try PatchProjectLibrary.installImportedPackage(
                    data: data,
                    decoded: decoded,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin
                )
                PatchProjectLibrary.setCategory(assignedCategory, for: summary.packageID)
                PatchProjectLibrary.setFeatureCategory(assignedFeature, for: summary.packageID)
                if let remoteID {
                    PatchProjectLibrary.setRemotePackageID(summary.packageID, for: remoteID)
                    PatchProjectLibrary.setRemoteVersion(remoteVersion ?? 0, for: remoteID)
                    if let remoteName { PatchProjectLibrary.setDisplayName(remoteName, for: summary.packageID) }
                }
            } catch {
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
            return nil
        }
        let decoded = try PatchPackageCodec.decode(data, password: nil)
        try PatchProjectLibrary.installImportedPackage(
            data: data,
            decoded: decoded,
            summary: summary,
            existingURL: existingURL,
            origin: origin
        )
        PatchProjectLibrary.setCategory(assignedCategory, for: summary.packageID)
        PatchProjectLibrary.setFeatureCategory(assignedFeature, for: summary.packageID)
        if let remoteID {
            PatchProjectLibrary.setRemotePackageID(summary.packageID, for: remoteID)
            PatchProjectLibrary.setRemoteVersion(remoteVersion ?? 0, for: remoteID)
            if let remoteName { PatchProjectLibrary.setDisplayName(remoteName, for: summary.packageID) }
        }
        return nil
    }

    private func clearPendingUnlock() {
        pendingUnlock = nil
        passwordRequest = nil
        unlockErrorKey = nil
    }

    private func finishOperation(successMessageKey: String) {
        reload()
        isBusy = false
        alert = PatchStoreAlert(titleKey: "common.done", messageKey: successMessageKey)
    }

    private func failOperation(_ error: PatchPackageError) {
        isBusy = false
        present(error)
    }

    private func failUnlock(_ error: PatchPackageError) {
        isBusy = false
        // Keep the password sheet open so the user can retry.
        // Presenting an alert while dismissing the sheet swallows the message.
        if case .invalidPasswordOrCorruptedPackage = error {
            unlockErrorKey = "patch.error.wrong_password"
        } else {
            unlockErrorKey = error.localizationKey
        }
    }

    private func present(_ error: PatchPackageError) {
        alert = PatchStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey,
            messageArgument: error.localizationArgument
        )
    }
}
