import CryptoKit
import Foundation
import UIKit

enum RemotePatchConfiguration {
    static let baseURL = URL(string: "https://systemstore-9su6ubez.manus.space")!
    static let syncToken = "3105-sync-v1-9f2d7a4c"
    static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
}

// NOTE: Full file recovery in progress - this is a temporary minimal stub.
// The complete PatchProjectStore will be restored in the next commit.

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

    init(autoLoad: Bool = true) {
        if autoLoad { activate() }
    }

    func activate() {
        isBusy = true
        Task.detached { [weak self] in
            let loaded = PatchProjectLibrary.load()
            await MainActor.run {
                self?.items = loaded
                self?.isBusy = false
            }
        }
    }

    func deactivateAndClear() {
        items = []
        isBusy = false
        alert = nil
        passwordRequest = nil
    }

    func reload() { items = PatchProjectLibrary.load() }
    func startRemoteSync() {}
    func stopRemoteSync() {}
    func syncNow() {}

    func applyInline(_ item: PatchLibraryItem) {
        guard !isBusy else { return }
        guard let project = item.project else {
            requestUnlock(for: item)
            return
        }
        guard DevicePatchService.latestReceipt(projectID: item.id) == nil else {
            alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.error.already_applied", messageArgument: "Já aplicado")
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    self?.reload()
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message", messageArgument: "Patch aplicado com sucesso.")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    self?.isBusy = false
                    let msg: String
                    if case .targetAppUnavailable(let b) = error {
                        msg = "App alvo não encontrado (\(b)). Abra o Free Fire e confirme o exploit."
                    } else {
                        msg = error.errorDescription ?? "Falha ao aplicar"
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
        guard !isBusy, let receipt = DevicePatchService.latestReceipt(projectID: item.id) else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: true)
                await MainActor.run {
                    self?.reload()
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message", messageArgument: "Patch restaurado.")
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore", messageArgument: "Falha ao restaurar.")
                }
            }
        }
    }

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
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
                guard let item = await MainActor.run(body: { self?.items.first(where: { $0.id == request.summary.packageID }) }) else {
                    throw PatchPackageError.invalidProject
                }
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
                    self?.alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message", messageArgument: "Patch desbloqueado. Toque de novo para aplicar.")
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

    func clearUnlockError() {
        unlockErrorKey = nil
    }
}
