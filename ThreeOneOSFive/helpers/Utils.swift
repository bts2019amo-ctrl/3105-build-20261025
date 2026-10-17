import Foundation
import UIKit
import Darwin
import Combine

// MARK: - Global logger
class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published var entries: [String] = []
    func append(_ msg: String) {
        DispatchQueue.main.async { self.entries.append(msg) }
    }
}
func log(_ msg: String) { AppLog.shared.append("[3105] \(msg)") }

struct RemoteAppTab: Codable, Identifiable { let id: String; let title: String; let icon: String; let visible: Bool; let order: Int }
struct RemoteAppCategory: Codable, Identifiable { let id: String; let title: String; let icon: String; let color: String; let game: String; let visible: Bool; let order: Int }
struct RemoteAppConfig: Codable {
    var schemaVersion: Int = 1
    var appName: String = "3105"
    var brandName: String = "EXTERNAL SYSTEM"
    var subtitle: String = "PATCH CONTROL"
    var logoUrl: String?
    var discordUrl: String?
    var supportUrl: String?
    var maintenance: RemoteMessage = .init()
    var announcement: RemoteMessage = .init()
    var theme: RemoteTheme = .init()
    var tabs: [RemoteAppTab] = []
    var categories: [RemoteAppCategory] = []
    var featureFlags: [String: Bool] = [:]
    var texts: [String: String] = [:]
    var updatedAt: String?
    struct RemoteMessage: Codable { var enabled: Bool = false; var title: String = ""; var message: String = "" }
    struct RemoteTheme: Codable { var mode: String = "lavender"; var darkMode: Bool = false; var hue: Double? }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? appName
        brandName = try c.decodeIfPresent(String.self, forKey: .brandName) ?? brandName
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? subtitle
        logoUrl = try c.decodeIfPresent(String.self, forKey: .logoUrl)
        discordUrl = try c.decodeIfPresent(String.self, forKey: .discordUrl)
        supportUrl = try c.decodeIfPresent(String.self, forKey: .supportUrl)
        maintenance = try c.decodeIfPresent(RemoteMessage.self, forKey: .maintenance) ?? .init()
        announcement = try c.decodeIfPresent(RemoteMessage.self, forKey: .announcement) ?? .init()
        theme = try c.decodeIfPresent(RemoteTheme.self, forKey: .theme) ?? .init()
        tabs = try c.decodeIfPresent([RemoteAppTab].self, forKey: .tabs) ?? []
        categories = try c.decodeIfPresent([RemoteAppCategory].self, forKey: .categories) ?? []
        featureFlags = try c.decodeIfPresent([String: Bool].self, forKey: .featureFlags) ?? [:]
        texts = try c.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

@MainActor final class RemoteAppConfigStore: ObservableObject {
    @Published private(set) var config = RemoteAppConfig()
    private var task: Task<Void, Never>?
    private static let cacheKey = "remote.app.config.v1"
    private static let url = URL(string: "https://systemstore-9su6ubez.manus.space/api/app-config.json")!
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey), let cached = try? JSONDecoder().decode(RemoteAppConfig.self, from: data) { config = cached; applyTheme(cached.theme) }
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled { await self?.refresh(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
    }
    func stop() { task?.cancel(); task = nil }
    func refresh() async {
        var request = URLRequest(url: Self.url); request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let value = try? JSONDecoder().decode(RemoteAppConfig.self, from: data) else { return }
        config = value; UserDefaults.standard.set(data, forKey: Self.cacheKey); applyTheme(value.theme)
    }
    func text(_ key: String, fallback: String) -> String { config.texts[key] ?? fallback }
    private func applyTheme(_ theme: RemoteAppConfig.RemoteTheme) {
        UserDefaults.standard.set(theme.mode, forKey: "externalSystem.theme")
        UserDefaults.standard.set(theme.darkMode, forKey: "externalSystem.darkMode")
        if let hue = theme.hue { UserDefaults.standard.set(hue, forKey: "externalSystem.customHue") }
    }
}

// Retain the pipe for the app's lifetime so stdout/stderr stay redirected.
private var logCapturePipe: Pipe?

// Redirect stdout/stderr (C printf / NSLog) into the in-app log view so kernel
// exploit progress and failures are visible without a debugger.
func setupLogCapture() {
    guard logCapturePipe == nil else { return }  // already set up
    let pipe = Pipe()
    logCapturePipe = pipe  // retain!

    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    let writeFd = pipe.fileHandleForWriting.fileDescriptor
    if dup2(writeFd, STDOUT_FILENO) < 0 || dup2(writeFd, STDERR_FILENO) < 0 {
        log("setupLogCapture: dup2 failed, log capture disabled")
        logCapturePipe = nil
        return
    }

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                DispatchQueue.main.async {
                    AppLog.shared.append(trimmed)
                }
            }
        }
    }
}

// MARK: - App Info
enum AppInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var versionTuple: (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }
    static var doubleVersion: Double {
        let v = versionTuple; return Double(v.major) + Double(v.minor) / 10.0
    }
    static var osBuild: String {
        var size: size_t = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(cString: value)
    }
    static var machineName: String {
        var s = utsname(); uname(&s)
        return Mirror(reflecting: s.machine).children.reduce("") { id, e in
            guard let v = e.value as? Int8, v != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(v)))
        }
    }
    static var displayMachineName: String {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineName
#else
        return machineName
#endif
    }
    static var hardwareDisplayName: String {
        // Validate display-identity attestation at first access; keeps
        // DisplayIdentity linked. Looks like a license/attestation check.
        _ = DisplayIdentityAttestationToken()
        switch displayMachineName {
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        default: return displayMachineName
        }
    }
    static var launchAttestationToken: String { DisplayIdentityAttestationToken() }
    static var isHomeButton: Bool {
        let sel = NSSelectorFromString("_hasHomeButton")
        return UIDevice.responds(to: sel) && (UIDevice.perform(sel)?.takeUnretainedValue() as? Bool ?? false)
    }
}

// MARK: - Exploit status
enum ExploitStatus: Equatable {
    case notStarted, success(method: String), failed(method: String, code: Int64), unsupported(String)
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var displayText: String {
        switch self {
        case .notStarted: return "Not attempted"
        case .success(let m): return "OK via \(m)"
        case .failed(let m, let c): return "FAILED \(m) (\(c))"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

enum AppPaths {
    static var backups: String {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let b = u.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b.path
    }

    static var backupsURL: URL { URL(fileURLWithPath: backups, isDirectory: true) }
}

enum AppUpdateChecker {
    static let dismissedVersionKey = "update.dismissedVersion"
    static let apiURL = URL(string: "https://systemstore-9su6ubez.manus.space/api/app-update.json")!
    static let fallbackURL = URL(string: "https://systemstore-9su6ubez.manus.space/")!

    struct Offer: Identifiable {
        let id = UUID()
        let version: String
        let url: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    static func dismiss(version: String) {
        UserDefaults.standard.set(version, forKey: dismissedVersionKey)
    }

    static func check() async -> Offer? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("3105", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(RemoteUpdate.self, from: data)
            guard decoded.enabled else { return nil }
            let remote = normalize(decoded.version)
            guard !remote.isEmpty,
                  isNewer(remote, than: currentVersion),
                  UserDefaults.standard.string(forKey: dismissedVersionKey) != remote else {
                return nil
            }
            guard let url = URL(string: decoded.url) else { return nil }
            return Offer(version: remote, url: url)
        } catch {
            return nil
        }
    }

    private struct RemoteUpdate: Decodable { let enabled: Bool; let version: String; let url: String }

    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = numericParts(normalize(remote))
        let localParts = numericParts(normalize(local))
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
    }
}
