import SwiftUI
import UIKit
import Security
import CryptoKit
import MachO

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
    @State private var showOnboarding = false
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
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
                        AppUpdateChecker.dismiss(version: offer.version)
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
                guard phase == .active, keySession.isAuthenticated, !showOnboarding else { return }
                Task { await keySession.refresh() }
                appState.detectSupport()
            }
            .onOpenURL { url in
                guard keySession.isAuthenticated else { return }
                patchDraftCoordinator.presentImport(url)
            }
            .tint(AppTheme.accent)
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

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
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
    let message: String?
    let reason: String?
    let expiresAt: String?
}

@MainActor
final class IOSKeySession: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isChecking = false
    @Published private(set) var expiresAt: Date?
    @Published var errorMessage: String?

    private static let endpoint = URL(string: "https://proxysystem.org/api/trpc/proxyKeys.publicCheckKey")!
    private static let keychainService = "com.3105.ios-key"
    private static let keychainAccount = "proxy-system-key"
    private var storedKey: String?
    private var monitorTask: Task<Void, Never>?

    init() {
        Self.enforceInstallationIdentity()
        if !RuntimeIntegrityGuard.passesBundleIdentityCheck()
            || !RuntimeIntegrityGuard.passesLoadedImageCheck() {
            try? PatchProjectLibrary.resetAll()
            PatchKeyStore.deleteAll()
            Self.deleteKeychain()
            fatalError("Bundle integrity validation failed")
        }
        storedKey = Self.readKeychain()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
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
        errorMessage = nil
        Self.deleteKeychain()
    }

    private func validate(_ key: String, saveOnSuccess: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
            let input: [String: Any] = [
                "json": ["key": key, "deviceId": Self.deviceIdentifier]
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
                errorMessage = result.message ?? result.reason ?? "Chave inválida ou expirada."
                return
            }

            storedKey = key
            if saveOnSuccess { Self.writeKeychain(key) }
            expiresAt = result.expiresAt.flatMap(Self.parseDate)
            errorMessage = nil
            isAuthenticated = true
        } catch {
            if !isAuthenticated {
                errorMessage = "Não foi possível verificar a chave. Verifique sua conexão."
            }
        }
    }

    private static var deviceIdentifier: String {
        if let identifier = UIDevice.current.identifierForVendor?.uuidString {
            return identifier
        }
        let key = "ios.device.identifier"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func enforceInstallationIdentity() {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let executableHash = executableDigest() ?? "unavailable"
        let bundleHash = bundleDigest() ?? "unavailable"
        let fingerprint = "\(bundleID)|\(bundleName)|\(version)|\(build)|\(executableHash)|\(bundleHash)"
        let identityKey = "installation.identity.fingerprint"
        if let previous = UserDefaults.standard.string(forKey: identityKey), previous != fingerprint {
            try? PatchProjectLibrary.resetAll()
            deleteKeychain()
        }
        UserDefaults.standard.set(fingerprint, forKey: identityKey)
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
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var digestInput = Data()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true,
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            digestInput.append(contentsOf: Data(relativePath.utf8))
            digestInput.append(0)
            digestInput.append(contentsOf: data)
            digestInput.append(0)
        }
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ value: String) -> Date? {
        dateFormatter.date(from: value) ?? dateFormatterWithoutFractionalSeconds.date(from: value)
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
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
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
}

enum RuntimeIntegrityGuard {
    private static let expectedBundleIdentifier = "com.apple.mobile.MobileHouseArrest"
    private static let expectedBundleName = "3105"
    private static let expectedDisplayName = "EXTERNAL SYSTEM"
    private static let expectedAssetsDigest = "57da4706ab2b7faa4ede4869e9e1c48ca58a863ae826796181273d5ad6cd6749"

    static func passesBundleIdentityCheck() -> Bool {
        guard Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == expectedBundleName,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == expectedDisplayName else {
            return false
        }
        let assetsURL = Bundle.main.bundleURL.appendingPathComponent("Assets.car", isDirectory: false)
        guard FileManager.default.fileExists(atPath: assetsURL.path),
              let assetsData = try? Data(contentsOf: assetsURL, options: [.mappedIfSafe]) else {
            return false
        }
        let digest = SHA256.hash(data: assetsData)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == expectedAssetsDigest
    }

    static func passesLoadedImageCheck() -> Bool {
        #if arch(arm64)
        // Supported device architecture.
        #else
        return false
        #endif
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let extensionName = url.pathExtension.lowercased()
                let filename = url.lastPathComponent.lowercased()
                let suspiciousExtensions = [
                    "dylib", "framework", "bundle", "deb", "so", "frida", "js"
                ]
                let suspiciousNames = [
                    "frida", "fridagadget", "frida-agent", "substrate", "substitute",
                    "libhooker", "ellekit", "cycript"
                ]
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true
                    || suspiciousExtensions.contains(extensionName)
                    || suspiciousNames.contains(where: { filename.contains($0) }) {
                    return false
                }
            }
        }
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            guard let pointer = _dyld_get_image_name(index),
                  let rawPath = String(validatingUTF8: pointer) else { continue }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let isSystemImage = path.hasPrefix("/System/Library/")
                || path.hasPrefix("/usr/lib/")
                || path.hasPrefix("/usr/libexec/")
            let isBundleDynamicImage = path.hasPrefix(bundlePath)
                && (path.lowercased().hasSuffix(".dylib")
                    || path.lowercased().contains(".framework/"))
            if !isSystemImage && isBundleDynamicImage {
                return false
            }
        }
        return true
    }
}

struct IOSKeyLoginView: View {
    @ObservedObject var session: IOSKeySession
    @State private var key = ""

    var body: some View {
        ZStack {
            AnimatedGlassWallpaper()
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    Spacer(minLength: 44)
                    AppLogo(size: 76)
                        .shadow(color: AppTheme.accent.opacity(0.35), radius: 22)
                    Text("EXTERNAL SYSTEM")
                        .font(.headline.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(.primary)
                    VStack(spacing: 8) {
                        Text("Acesso protegido")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Digite sua chave iOS para carregar os patches remotamente.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("CHAVE IOS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                            .tracking(1.2)
                        TextField("PROXY-SYSTEM-...", text: $key)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .padding(16)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.accent.opacity(0.28)))
                    }

                    if let error = session.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        session.submit(key)
                    } label: {
                        Group {
                            if session.isChecking {
                                ProgressView().tint(.white)
                            } else {
                                Text("Validar e entrar")
                                    .font(.headline.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(session.isChecking)

                    Text("Os patches não ficam dentro da IPA. Eles só aparecem depois da validação da chave.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 34)
            }
        }
        .tint(AppTheme.accent)
    }
}
