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
                guard phase == .active, !showOnboarding else { return }
                guard keySession.isAuthenticated else { return }
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
    private(set) static var runtimeAuthorized = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isChecking = false
    @Published private(set) var expiresAt: Date?
    @Published var errorMessage: String?

    private static let endpoint = URL(string: "https://proxysystem.org/api/trpc/proxyKeys.publicCheckKey")!
    private static let keychainService = "com.3105.ios-key"
    private static let keychainAccount = "proxy-system-key"
    private static let identityKeychainService = "com.3105.installation-integrity"
    private static let identityKeychainAccount = "bundle-fingerprint"
    private var storedKey: String?
    private var monitorTask: Task<Void, Never>?

    init() {
        Self.enforceInstallationIdentity()
        if !RuntimeIntegrityGuard.passesBundleIdentityCheck()
            || !RuntimeIntegrityGuard.passesLoadedImageCheck()
            || RuntimeIntegrityGuard.hasForbiddenBundleArtifact()
            || !RuntimeIntegrityGuard.passesRuntimeSecurityCheck()
            || !RuntimeIntegrityGuard.passesInstallationBaseline() {
            try? PatchProjectLibrary.resetAll()
            PatchKeyStore.deleteAll()
            Self.deleteKeychain()
            Self.runtimeAuthorized = false
            fatalError("Application integrity check failed")
        }
        storedKey = Self.readKeychain()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                guard RuntimeIntegrityGuard.passesLoadedImageCheck(),
                      !RuntimeIntegrityGuard.hasForbiddenBundleArtifact(),
                      RuntimeIntegrityGuard.passesRuntimeSecurityCheck(),
                      RuntimeIntegrityGuard.passesInstallationBaseline() else {
                    await self?.invalidateForIntegrityFailure()
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

    private func invalidateForIntegrityFailure() {
        try? PatchProjectLibrary.resetAll()
        PatchKeyStore.deleteAll()
        Self.deleteKeychain()
        Self.runtimeAuthorized = false
        isAuthenticated = false
        errorMessage = "A integridade do aplicativo foi alterada. Instale uma cópia oficial."
        fatalError("Runtime integrity check failed")
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
            Self.runtimeAuthorized = true
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
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "unknown"
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

    static func installationBaselineMatches() -> Bool {
        let fingerprint = installationFingerprint
        return UserDefaults.standard.string(forKey: "installation.identity.fingerprint") == fingerprint
            && readInstallationBaseline() == fingerprint
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
}

enum RuntimeIntegrityGuard {
    private static let expectedBundleIdentifier = "com.apple.mobile.MobileHouseArrest"
    private static let expectedBundleName = "EXTERNAL SYSTEM"
    private static let expectedDisplayName = "EXTERNAL SYSTEM"

    static func hasForbiddenBundleArtifact() -> Bool {
#if targetEnvironment(simulator)
        return false
#else
        let environment = ProcessInfo.processInfo.environment
        if environment["DYLD_INSERT_LIBRARIES"] != nil
            || environment["DYLD_LIBRARY_PATH"] != nil
            || environment["DYLD_FRAMEWORK_PATH"] != nil {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return false }
        for case let url as URL in enumerator {
            let extensionName = url.pathExtension.lowercased()
            let lowerName = url.lastPathComponent.lowercased()
            if extensionName == "dylib" || extensionName == "deb" || extensionName == "so"
                || lowerName.contains("frida")
                || lowerName.contains("substrate")
                || lowerName.contains("libhooker")
                || lowerName.contains("substitute")
                || lowerName.contains("cycript")
                || lowerName.contains("flex") {
                return true
            }
        }
        return false
#endif
    }

    static func passesBundleIdentityCheck() -> Bool {
        guard Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == expectedBundleName,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == expectedDisplayName else {
            return false
        }
        guard let executableURL = Bundle.main.executableURL,
              executableURL.path.hasPrefix(Bundle.main.bundleURL.path + "/"),
              FileManager.default.isReadableFile(atPath: executableURL.path),
              Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            return false
        }
        return true
    }

    static func passesRuntimeSecurityCheck() -> Bool {
#if targetEnvironment(simulator)
        return true
#else
        guard !isDebuggerAttached(), !hasJailbreakArtifacts() else { return false }
        let suspiciousPaths = [
            "/usr/lib/TweakInject",
            "/Library/MobileSubstrate",
            "/Library/Frameworks/CydiaSubstrate.framework",
            "/var/jb",
            "/var/binpack",
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app"
        ]
        return !suspiciousPaths.contains { FileManager.default.fileExists(atPath: $0) }
#endif
    }

    private static func hasJailbreakArtifacts() -> Bool {
        let paths = [
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/bin/bash",
            "/etc/apt",
            "/private/var/stash",
            "/private/var/lib/apt"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func isDebuggerAttached() -> Bool {
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &processInfo, &size, nil, 0)
        }
        guard result == 0 else { return true }
        return (processInfo.kp_proc.p_flag & P_TRACED) != 0
    }

    @MainActor
    static func passesInstallationBaseline() -> Bool {
        IOSKeySession.installationBaselineMatches()
    }

    static func passesLoadedImageCheck() -> Bool {
#if targetEnvironment(simulator)
        return true
#else
        #if arch(arm64)
        // Supported device architecture.
        #else
        return false
        #endif
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(
            at: Bundle.main.bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let extensionName = url.pathExtension.lowercased()
                if extensionName == "dylib"
                    || extensionName == "deb" {
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
            let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
            let isBundleForbiddenFile = path.hasPrefix(bundlePath)
                && (extensionName == "dylib" || extensionName == "deb")
            let lowerPath = path.lowercased()
            let isInjectedImage = lowerPath.contains("frida")
                || lowerPath.contains("substrate")
                || lowerPath.contains("libhooker")
                || lowerPath.contains("substitute")
                || lowerPath.contains("cycript")
                || lowerPath.contains("tweakinject")
            if (!isSystemImage && isBundleForbiddenFile) || isInjectedImage {
                return false
            }
        }
        return true
#endif
    }
}

struct IOSKeyLoginView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var session: IOSKeySession
    @State private var key = ""
    @State private var isKeyVisible = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 64)

                    AppLogo(size: 78)
                        .padding(.bottom, 20)

                    Text(language.text("brand.external_system"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(language.text("login.subtitle"))
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                        .padding(.horizontal, 20)

                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22)

                            Group {
                                if isKeyVisible {
                                    TextField(language.text("login.key_placeholder"), text: $key)
                                } else {
                                    SecureField(language.text("login.key_placeholder"), text: $key)
                                }
                            }
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .frame(width: 28, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(language.text(isKeyVisible ? "login.hide_key" : "login.show_key"))
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 56)
                        .background(Color(red: 0.20, green: 0.20, blue: 0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        }

                        Button {
                            session.submit(key)
                        } label: {
                            Group {
                                if session.isChecking {
                                    ProgressView().tint(Color(red: 0.20, green: 0.24, blue: 0.28))
                                } else {
                                    HStack(spacing: 12) {
                                        Text(language.text("login.enter"))
                                        Image(systemName: "arrow.right")
                                    }
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                }
                            }
                            .foregroundStyle(Color(red: 0.29, green: 0.34, blue: 0.39))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                        }
                        .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .disabled(session.isChecking)

                        Button {
                            if let clipboardKey = UIPasteboard.general.string {
                                key = clipboardKey
                            }
                        } label: {
                            Label(language.text("login.paste_key"), systemImage: "doc.on.clipboard")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Button {
                            session.logout()
                            key = ""
                        } label: {
                            Label(language.text("login.clear_external"), systemImage: "trash")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(24)
                    .background(Color(red: 0.105, green: 0.105, blue: 0.12), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.top, 36)
                    .padding(.horizontal, 28)

                    Label(language.text("login.official_version"), systemImage: "checkmark.shield.fill")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.top, 34)

                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity)
            }
            .dynamicTypeSize(.large)
        }
        .tint(AppTheme.accent)
    }
}
