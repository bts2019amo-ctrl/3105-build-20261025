import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    static let baseURL = URL(string: "https://systemstore-9su6ubez.manus.space")!
    static let syncToken = "3105-sync-v1-9f2d7a4c"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}

enum RemoteSyncState: Equatable {
    case idle, syncing, online, offline
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

    private var isActivated = false

    init(autoLoad: Bool = true) {
        if autoLoad { activate() }
    }

    func activate() {
        guard IOSKeySession.runtimeAuthorized, !isActivated else { return }
        isActivated = true
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = PatchProjectLibrary.load()
            await MainActor.run {
                self?.items = loaded
                self?.isBusy = false
            }
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

    func reload() { items = PatchProjectLibrary.load() }
    func startRemoteSync() {}
    func stopRemoteSync() {}
    func syncNow() {
        Task {
            items = await Task.detached { PatchProjectLibrary.load() }.value
        }
    }

    func applyInline(_ item: PatchLibraryItem) {
        guard !isBusy else {
            alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply", messageArgument: "Aguarde o patch anterior terminar.")
            return
        }
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
                let synchronized: PatchProject
                if item.summary.schemaVersion >= 2 && item.canInspectContents {
                    synchronized = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                } else {
                    synchronized = project
                }
                _ = try DevicePatchService.apply(project: synchronized)
                await MainActor.run {
                    self?.reload()
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message", messageArgument: "Patch aplicado com sucesso.")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    self?.isBusy = false
                    let msg: String
                    switch error {
                    case .targetAppUnavailable(let bundle):
                        msg = "App alvo não encontrado (\(bundle)). Abra o Free Fire pelo menos 1x e confirme que o exploit está ativo."
                    case .applyFailed:
                        msg = "Falha ao aplicar. Free Fire instalado? Exploit ativo?"
                    default:
                        msg = error.errorDescription ?? error.localizationKey
                    }
                    self?.alert = PatchStoreAlert(titleKey: "common.failed", messageKey: error.localizationKey, messageArgument: msg)
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply", messageArgument: "Falha ao aplicar o patch.")
                }
            }
        }
    }

    func restoreInline(_ item: PatchLibraryItem) {
        guard !isBusy else { return }
        guard let receipt = DevicePatchService.latestReceipt(projectID: item.id) else {
            alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore", messageArgument: "Nenhum backup encontrado para restaurar.")
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: true)
                await MainActor.run {
                    self?.reload()
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message", messageArgument: "Patch restaurado (original).")
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore", messageArgument: "Falha ao restaurar o patch.")
                }
            }
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
                let item = await MainActor.run { self?.items.first(where: { $0.id == packageID }) }
                guard let item else { throw PatchPackageError.invalidProject }
                let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
                let decoded = try PatchPackageCodec.decode(data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: request.summary)
                try PatchProjectLibrary.installImportedPackage(
                    data: data,
                    decoded: decoded,
                    summary: request.summary,
                    existingURL: item.packageURL,
                    origin: item.origin
                )
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

    func cancelUnlock() {
        passwordRequest = nil
        unlockErrorKey = nil
    }

    func clearUnlockError() { unlockErrorKey = nil }

    // Stubs for APIs used elsewhere — keep app compiling
    func importPackage(at url: URL) {}
    func importPackage(fromRemoteURL url: URL) {}
    func importPackage(from source: Any) {}
    func create(project: PatchProject, password: String?) {}
}
