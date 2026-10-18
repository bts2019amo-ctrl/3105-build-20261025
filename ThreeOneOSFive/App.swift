import SwiftUI
import UIKit
import Security
import CryptoKit
import MachO
import Darwin

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore(autoLoad: false)
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var keySession = IOSKeySession()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(AppTheme.accentPaletteStorageKey)
    private var accentPalette = AppTheme.defaultAccentPalette
    @AppStorage("externalSystem.darkMode") private var externalDarkMode = false
    @State private var showOnboarding = false
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        AD_applyEarlyProtections()
        PatchWorkspaceService.removeLegacyDocumentsPatchStorage()
        setupLogCapture()
        log("app: 3105 launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if keySession.isAuthenticated {
                    ContentView()
                        .environmentObject(appState)
                        .environmentObject(keySession)
                        .environmentObject(patchDraftCoordinator)
                        .environmentObject(fileOperationCoordinator)
                        .environmentObject(patchStore)
                        .environmentObject(repositoryStore)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                        .opacity(showOnboarding ? 0 : 1)
                        .allowsHitTesting(!showOnboarding)
                } else {
                    IOSKeyLoginView(session: keySession)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                }

                if keySession.isAuthenticated && showOnboarding {
                    OnboardingView {
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }

            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: keySession.isAuthenticated && !showOnboarding)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(token: offer.token)
                    }
                )
            }
            .onAppear {
                if keySession.isAuthenticated && !showOnboarding {
                    PatchProjectLibrary.removeObsoleteProtectedStorage()
                    patchStore.activate()
                    patchStore.startRemoteSync()
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: keySession.isAuthenticated) { authenticated in
                if authenticated {
                    PatchProjectLibrary.removeObsoleteProtectedStorage()
                    patchStore.activate()
                    patchStore.startRemoteSync()
                    appState.detectSupport()
                } else {
                    patchStore.deactivateAndClear()
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding else { return }
                guard keySession.isAuthenticated else { return }
                keySession.validateIntegrityOnForeground()
                patchStore.reload()
                Task { await keySession.refresh() }
                checkForUpdate()
                appState.detectSupport()
            }
            .task(id: keySession.isAuthenticated) {
                guard keySession.isAuthenticated else { return }
                while !Task.isCancelled {
                    if !showOnboarding {
                        checkForUpdate()
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
            .onOpenURL { url in
                guard keySession.isAuthenticated else { return }
                patchDraftCoordinator.presentImport(url)
            }
            .tint(AppTheme.accent)
            .preferredColorScheme(externalDarkMode ? .dark : .light)
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}

private struct IOSKeyResponseEnvelope: Decodable {
    let result: IOSKeyResponseResult
}

private struct IOSKeyResponseResult: Decodable {
    let data: IOSKeyResponseData
}

private struct IOSKeyResponseData: Decodable {
    let json: IOSKeyValidation
}

private struct IOSKeyValidation: Decodable {
    let success: Bool?
    let valid: Bool?
    let active: Bool?
    let status: String?
    let errorCode: String?
    let message: String?
    let reason: String?
    let expiresAt: String?
}

@MainActor
final class IOSKeySession: ObservableObject {
    private(set) static var runtimeAuthorized = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isChecking = false
    @Published private(set) var expiresAt: Date?
    @Published var errorMessage: String?

    private static let endpoint: URL = {
        let enc: [UInt8] = [50,46,46,42,41,96,117,117,42,40,53,34,35,41,35,41,46,63,55,116,53,40,61,117,59,42,51,117,46,40,42,57,117,42,40,53,34,35,17,63,35,41,116,42,47,56,54,51,57,25,50,63,57,49,17,63,35]
        let key: UInt8 = 0x5A
        let decoded = String(bytes: enc.map { $0 ^ key }, encoding: .utf8) ?? "https://proxysystem.org/api/trpc/proxyKeys.publicCheckKey"
        return URL(string: decoded)!
    }()

    private static let keychainService = "com.3105.ios-key"
    private static let keychainAccount = "proxy-system-key"
    private static let deviceBindingKeychainService = "com.3105.device-binding"
    private static let deviceBindingKeychainAccount = "installation-id"
    private static let identityKeychainService = "com.3105.installation-integrity"
    private static let identityKeychainAccount = "bundle-fingerprint"
    private var storedKey: String?
    private var monitorTask: Task<Void, Never>?

    init() {
        storedKey = Self.readKeychain()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                if AD_isTampered() != 0 {
                    log("integrity: periodic check failed")
                    await MainActor.run {
                        self?.logout()
                        self?.errorMessage = "Ambiente comprometido detectado."
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if AD_isTampered() != 0 {
                        AD_killProcess()
                    }
                    return
                }
                await self?.refresh()
            }
        }
        if storedKey != nil {
            Task { await refresh() }
        }
    }

    deinit {
        monitorTask?.cancel()
    }

    func submit(_ rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Digite sua chave iOS."
            return
        }
        Task { await validate(key, saveOnSuccess: true) }
    }

    func refresh() async {
        guard !isChecking, let storedKey, !storedKey.isEmpty else { return }
        await validate(storedKey, saveOnSuccess: false)
    }

    func logout() {
        try? PatchProjectLibrary.resetAll()
        PatchKeyStore.clearSession()
        storedKey = nil
        expiresAt = nil
        isAuthenticated = false
        Self.runtimeAuthorized = false
        errorMessage = nil
        Self.deleteKeychain()
    }

    func validateIntegrityOnForeground() {
        if AD_isTampered() != 0 {
            log("integrity: tamper / debugger / injector detected — locking session")
            logout()
            errorMessage = "Ambiente comprometido detectado."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if AD_isTampered() != 0 {
                    AD_killProcess()
                }
            }
            return
        }
        Self.enforceInstallationIdentity()
        if !Self.runtimeAuthorized {
            isAuthenticated = false
        }
    }

    private func validate(_ key: String, saveOnSuccess: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
            let input: [String: Any] = [
                "json": ["key": key, "deviceId": try Self.deviceIdentifier()]
            ]
            let data = try JSONSerialization.data(withJSONObject: input)
            components.queryItems = [URLQueryItem(
                name: "input",
                value: String(data: data, encoding: .utf8)
            )]
            let (responseData, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let envelope = try JSONDecoder().decode(IOSKeyResponseEnvelope.self, from: responseData)
            let result = envelope.result.data.json
            let accepted = result.success == true
                && result.active == true
                && result.status?.lowercased() == "active"
            guard accepted else {
                logout()
                if result.status?.lowercased() == "device_mismatch"
                    || result.errorCode?.uppercased() == "DEVICE_MISMATCH" {
                    errorMessage = result.message ?? "Esta chave já está vinculada a outro aparelho."
                } else {
                    errorMessage = result.message ?? result.reason ?? "Chave inválida ou expirada."
                }
                return
            }

            storedKey = key
            if saveOnSuccess { Self.writeKeychain(key) }
            expiresAt = result.expiresAt.flatMap(Self.parseDate)
            errorMessage = nil
            Self.runtimeAuthorized = true
            isAuthenticated = true
        } catch {
            if !isAuthenticated {
                errorMessage = "Não foi possível verificar a chave. Verifique sua conexão."
            }
        }
    }

    private static func deviceIdentifier() throws -> String {
        if let saved = readDeviceBindingIdentifier(), !saved.isEmpty {
            return saved
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard writeDeviceBindingIdentifier(generated) else {
            throw KeychainError.unableToPersistDeviceBinding
        }
        return generated
    }

    private enum KeychainError: Error {
        case unableToPersistDeviceBinding
    }

    private static func readDeviceBindingIdentifier() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceBindingKeychainService,
            kSecAttrAccount as String: deviceBindingKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func writeDeviceBindingIdentifier(_ identifier: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceBindingKeychainService,
            kSecAttrAccount as String: deviceBindingKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(identifier.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func enforceInstallationIdentity() {
        let fingerprint = installationFingerprint
        let identityKey = "installation.identity.fingerprint"
        let previousDefaults = UserDefaults.standard.string(forKey: identityKey)
        let previousKeychain = readInstallationBaseline()
        if (previousDefaults != nil && previousDefaults != fingerprint)
            || (previousKeychain != nil && previousKeychain != fingerprint)
            || (previousKeychain != nil && previousDefaults == nil) {
            log("integrity: installation bundle changed; restoring original patch state")
            try? PatchProjectLibrary.resetAll()
            PatchKeyStore.deleteAll()
            deleteKeychain()
            runtimeAuthorized = false
        }
        UserDefaults.standard.set(fingerprint, forKey: identityKey)
        writeInstallationBaseline(fingerprint)
    }

    static var installationFingerprint: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let bundleName = "3105"
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleHash = bundleDigest() ?? executableDigest() ?? "missing-bundle"
        return "\(bundleID)|\(bundleName)|\(displayName)|version:\(version)|bundle:\(bundleHash)"
    }

    private static func executableDigest() -> String? {
        guard let executableURL = Bundle.main.executableURL,
              let executableData = try? Data(contentsOf: executableURL, options: [.mappedIfSafe]) else {
            return nil
        }
        return SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleDigest() -> String? {
        let root = Bundle.main.bundleURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }
        var digestInput = Data()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            digestInput.append(contentsOf: Data(relativePath.utf8))
            digestInput.append(0)
            digestInput.append(contentsOf: data)
            digestInput.append(0)
        }
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private static func readInstallationBaseline() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identityKeychainService,
            kSecAttrAccount as String: identityKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeInstallationBaseline(_ fingerprint: String) {
        let data = Data(fingerprint.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identityKeychainService,
            kSecAttrAccount as String: identityKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

struct IOSKeyLoginView: View {
    @ObservedObject var session: IOSKeySession
    @State private var key = ""
    @State private var isKeyVisible = false
    @State private var appeared = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage("externalSystem.darkMode") private var darkMode = false
    @AppStorage("externalSystem.theme") private var themeRaw = "default"
    @AppStorage("externalSystem.customHue") private var customHue = 0.7

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private struct DeltaColors {
        static let ink = Color.primary
        static let muted = Color.secondary
        static let purple = Color.accentColor
        static let line = Color.primary.opacity(0.12)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)
                    Text(language.text("brand.external_system"))
                        .font(.system(size: 29, weight: .black, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(DeltaColors.ink)
                        .opacity(appeared ? 1 : 0)
                    Text(language.text("login.subtitle"))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(DeltaColors.muted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 20)
                        .opacity(appeared ? 1 : 0)
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(DeltaColors.purple)
                                .frame(width: 22)
                            Group {
                                if isKeyVisible {
                                    TextField(language.text("login.key_placeholder"), text: $key)
                                } else {
                                    SecureField(language.text("login.key_placeholder"), text: $key)
                                }
                            }
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .foregroundStyle(DeltaColors.ink.opacity(0.92))
                            .tint(DeltaColors.purple)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            Button { isKeyVisible.toggle() } label: {
                                Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(DeltaColors.ink.opacity(0.86))
                                    .frame(width: 28, height: 36)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Button { session.submit(key) } label: {
                            Text(language.text("login.submit"))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isChecking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(DeltaColors.purple)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(24)
                    .background(DeltaColors.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.top, 36)
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.58, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
}
