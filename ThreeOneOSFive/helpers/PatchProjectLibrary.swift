import Foundation

enum PatchGameCategory: String, CaseIterable, Identifiable {
    case normal
    case max

    var id: String { rawValue }
}

enum PatchFeatureCategory: String, CaseIterable, Identifiable {
    case cache
    case avatar
    case hologram
    case external
    case skin

    var id: String { rawValue }
}

struct PatchLibraryItem: Identifiable {
    let summary: PatchPackageSummary
    var project: PatchProject?
    var contentKey: Data?
    var packageURL: URL
    let isAuthorCopy: Bool
    let origin: PatchPackageOrigin?

    var id: UUID { summary.packageID }
    var isLocked: Bool { project == nil }
    var canInspectContents: Bool {
        guard let project else { return false }
        return PatchProjectAccessPolicy.canInspectContents(
            project: project,
            isAuthorCopy: isAuthorCopy
        )
    }
    var workspaceURL: URL? {
        guard canInspectContents else { return nil }
        return PatchWorkspaceService.workspaceURL(projectID: id)
    }
}

struct PatchPasswordRequest: Identifiable {
    let summary: PatchPackageSummary
    let origin: PatchPackageOrigin?
    var id: UUID { summary.packageID }

    init(summary: PatchPackageSummary, origin: PatchPackageOrigin? = nil) {
        self.summary = summary
        self.origin = origin
    }
}

enum PatchProjectLibrary {
    private static let categoryDefaultsKey = "patch.game.category"
    private static let featureDefaultsKey = "patch.feature.category"
    private static let remoteDefaultsKey = "patch.remote.mapping"
    private static let remoteVersionKey = "patch.remote.version"
    private static let remotePatchVersionKey = "patch.remote.patch.version"
    private static let remoteChangelogKey = "patch.remote.changelog"
    private static let remoteChecksumKey = "patch.remote.checksum"
    private static let remoteNameKey = "patch.remote.name"
    private static let remoteIconKey = "patch.remote.icon"
    private static let selectedCategoryKey = "patch.game.selected.category"
    private static let selectedFeatureKey = "patch.feature.selected.category"
    private static let authorCopiesDirectoryName = ".AuthorCopies"
    private static let originsDirectoryName = ".Origins"

    static func packageRootURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("PatchProjects", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func load(fileManager: FileManager = .default) -> [PatchLibraryItem] {
        guard let root = try? packageRootURL(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [] }

        var byID: [UUID: PatchLibraryItem] = [:]
        for url in urls where url.pathExtension.lowercased() == "3105" {
            do {
                let data = try readPackage(at: url)
                let summary = try PatchPackageCodec.inspect(data)
                let decoded: DecodedPatchPackage?
                if let contentKey = try PatchKeyStore.load(for: summary) {
                    decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                } else if summary.isPasswordProtected {
                    decoded = nil
                } else {
                    decoded = try PatchPackageCodec.decode(data, password: nil)
                }
                let isAuthorCopy = isAuthorCopy(
                    packageID: summary.packageID,
                    fileManager: fileManager
                )
                let item = PatchLibraryItem(
                    summary: summary,
                    project: decoded?.project,
                    contentKey: decoded?.contentKey,
                    packageURL: url,
                    isAuthorCopy: isAuthorCopy,
                    origin: loadOrigin(
                        packageID: summary.packageID,
                        fileManager: fileManager
                    )
                )
                if summary.schemaVersion >= 2, let project = decoded?.project {
                    if PatchProjectAccessPolicy.shouldMaterializeWorkspace(
                        project: project,
                        isAuthorCopy: isAuthorCopy
                    ) {
                        do {
                            _ = try PatchWorkspaceService.ensureWorkspace(for: project)
                        } catch {
                            log("patch: workspace unavailable for \(project.id.uuidString)")
                        }
                    } else {
                        try? PatchWorkspaceService.deleteWorkspace(
                            projectID: project.id,
                            fileManager: fileManager
                        )
                    }
                }
                byID[summary.packageID] = item
            } catch {
                log("patch: skipped invalid local package \(url.lastPathComponent)")
            }
        }
        return byID.values.sorted {
            ($0.project?.updatedAt ?? .distantPast) > ($1.project?.updatedAt ?? .distantPast)
        }
    }

    static func category(for item: PatchLibraryItem) -> PatchGameCategory {
        let categories = UserDefaults.standard.dictionary(forKey: categoryDefaultsKey) as? [String: String]
        if let stored = categories?[item.id.uuidString], let category = PatchGameCategory(rawValue: stored) {
            return category
        }
        return item.project?.name.localizedCaseInsensitiveContains("max") == true ? .max : .normal
    }

    static func setCategory(_ category: PatchGameCategory, for packageID: UUID) {
        var categories = UserDefaults.standard.dictionary(forKey: categoryDefaultsKey) as? [String: String] ?? [:]
        categories[packageID.uuidString] = category.rawValue
        UserDefaults.standard.set(categories, forKey: categoryDefaultsKey)
    }

    static func featureCategory(for item: PatchLibraryItem) -> PatchFeatureCategory {
        let features = UserDefaults.standard.dictionary(forKey: featureDefaultsKey) as? [String: String]
        return features?[item.id.uuidString].flatMap(PatchFeatureCategory.init(rawValue:)) ?? .cache
    }

    static func setFeatureCategory(_ category: PatchFeatureCategory, for packageID: UUID) {
        var features = UserDefaults.standard.dictionary(forKey: featureDefaultsKey) as? [String: String] ?? [:]
        features[packageID.uuidString] = category.rawValue
        UserDefaults.standard.set(features, forKey: featureDefaultsKey)
    }

    static func remotePackageID(for remoteID: Int) -> UUID? {
        let mappings = UserDefaults.standard.dictionary(forKey: remoteDefaultsKey) as? [String: String]
        guard let value = mappings?[String(remoteID)] else { return nil }
        return UUID(uuidString: value)
    }

    static func setRemotePackageID(_ packageID: UUID, for remoteID: Int) {
        var mappings = UserDefaults.standard.dictionary(forKey: remoteDefaultsKey) as? [String: String] ?? [:]
        mappings[String(remoteID)] = packageID.uuidString
        UserDefaults.standard.set(mappings, forKey: remoteDefaultsKey)
    }

    static func remoteVersion(for remoteID: Int) -> Int64 {
        let versions = UserDefaults.standard.dictionary(forKey: remoteVersionKey) as? [String: NSNumber]
        return versions?[String(remoteID)]?.int64Value ?? 0
    }

    static func setRemoteVersion(_ version: Int64, for remoteID: Int) {
        var versions = UserDefaults.standard.dictionary(forKey: remoteVersionKey) as? [String: NSNumber] ?? [:]
        versions[String(remoteID)] = NSNumber(value: version)
        UserDefaults.standard.set(versions, forKey: remoteVersionKey)
    }

    static func setRemoteMetadata(version: Int, changelog: String?, checksum: String, for packageID: UUID) {
        var versions = UserDefaults.standard.dictionary(forKey: remotePatchVersionKey) as? [String: NSNumber] ?? [:]
        versions[packageID.uuidString] = NSNumber(value: version)
        UserDefaults.standard.set(versions, forKey: remotePatchVersionKey)
        var notes = UserDefaults.standard.dictionary(forKey: remoteChangelogKey) as? [String: String] ?? [:]
        notes[packageID.uuidString] = changelog ?? ""
        UserDefaults.standard.set(notes, forKey: remoteChangelogKey)
        var checksums = UserDefaults.standard.dictionary(forKey: remoteChecksumKey) as? [String: String] ?? [:]
        checksums[packageID.uuidString] = checksum
        UserDefaults.standard.set(checksums, forKey: remoteChecksumKey)
    }

    static func remoteMetadata(for packageID: UUID) -> (version: Int, changelog: String?, checksum: String?) {
        let versions = UserDefaults.standard.dictionary(forKey: remotePatchVersionKey) as? [String: NSNumber]
        let notes = UserDefaults.standard.dictionary(forKey: remoteChangelogKey) as? [String: String]
        let checksums = UserDefaults.standard.dictionary(forKey: remoteChecksumKey) as? [String: String]
        return (
            versions?[packageID.uuidString]?.intValue ?? 1,
            notes?[packageID.uuidString],
            checksums?[packageID.uuidString]
        )
    }

    static func clearRemoteMetadata(for packageID: UUID) {
        for key in [remotePatchVersionKey, remoteChangelogKey, remoteChecksumKey] {
            var values = UserDefaults.standard.dictionary(forKey: key) as? [String: Any] ?? [:]
            values.removeValue(forKey: packageID.uuidString)
            UserDefaults.standard.set(values, forKey: key)
        }
    }

    static func displayName(for item: PatchLibraryItem) -> String {
        let names = UserDefaults.standard.dictionary(forKey: remoteNameKey) as? [String: String]
        let name = names?[item.id.uuidString] ?? item.project?.name ?? ""
        guard name.lowercased().hasSuffix(".3105") else { return name }
        return String(name.dropLast(5))
    }

    static func setDisplayName(_ name: String, for packageID: UUID) {
        var names = UserDefaults.standard.dictionary(forKey: remoteNameKey) as? [String: String] ?? [:]
        names[packageID.uuidString] = name
        UserDefaults.standard.set(names, forKey: remoteNameKey)
    }

    static func setRemoteIconURL(_ url: String?, for packageID: UUID) {
        var icons = UserDefaults.standard.dictionary(forKey: remoteIconKey) as? [String: String] ?? [:]
        if let url, !url.isEmpty {
            icons[packageID.uuidString] = url
        } else {
            icons.removeValue(forKey: packageID.uuidString)
        }
        UserDefaults.standard.set(icons, forKey: remoteIconKey)
    }

    static func remoteIconURL(for packageID: UUID) -> URL? {
        let icons = UserDefaults.standard.dictionary(forKey: remoteIconKey) as? [String: String]
        guard let value = icons?[packageID.uuidString] else { return nil }
        return URL(string: value, relativeTo: RemotePatchConfiguration.baseURL)?.absoluteURL ?? URL(string: value)
    }

    static func removeRemotePackagesNotInFeed(
        remoteIDs: Set<Int>,
        fileManager: FileManager = .default
    ) {
        let mappings = UserDefaults.standard.dictionary(forKey: remoteDefaultsKey) as? [String: String] ?? [:]
        let itemsByID = Dictionary(uniqueKeysWithValues: load(fileManager: fileManager).map { ($0.id, $0) })
        for (remoteID, packageIDString) in mappings where !remoteIDs.contains(Int(remoteID) ?? -1) {
            if let packageID = UUID(uuidString: packageIDString) {
                if let item = itemsByID[packageID] {
                    deleteFilesImmediately(for: item, fileManager: fileManager)
                }
                setRemoteIconURL(nil, for: packageID)
                clearRemoteMetadata(for: packageID)
            }
        }
        let activeMappings = mappings.filter { remoteIDs.contains(Int($0.key) ?? -1) }
        UserDefaults.standard.set(activeMappings, forKey: remoteDefaultsKey)
    }

    static func resetAll(fileManager: FileManager = .default) throws {
        let root = try packageRootURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaceRoot = try PatchWorkspaceService.patchesRootURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: workspaceRoot.path) {
            try fileManager.removeItem(at: workspaceRoot)
        }
        [categoryDefaultsKey, featureDefaultsKey, remoteDefaultsKey, remoteVersionKey, remotePatchVersionKey, remoteChangelogKey, remoteChecksumKey, remoteNameKey, remoteIconKey]
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        PatchKeyStore.deleteAll()
    }

    static var selectedCategory: PatchGameCategory {
        PatchGameCategory(
            rawValue: UserDefaults.standard.string(forKey: selectedCategoryKey) ?? "normal"
        ) ?? .normal
    }

    static func setSelectedCategory(_ category: PatchGameCategory) {
        UserDefaults.standard.set(category.rawValue, forKey: selectedCategoryKey)
    }

    static var selectedFeatureCategory: PatchFeatureCategory {
        PatchFeatureCategory(
            rawValue: UserDefaults.standard.string(forKey: selectedFeatureKey) ?? "cache"
        ) ?? .cache
    }

    static func setSelectedFeatureCategory(_ category: PatchFeatureCategory) {
        UserDefaults.standard.set(category.rawValue, forKey: selectedFeatureKey)
    }

    static func readPackage(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let plaintext = try PatchKeyStore.decryptAtRest(data)
        if plaintext == data {
            try? PatchKeyStore.encryptAtRest(data).write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        }
        return plaintext
    }

    static func save(
        data: Data,
        projectName: String,
        existingURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination: URL
        if let existingURL {
            destination = existingURL
        } else {
            let root = try packageRootURL(fileManager: fileManager)
            let baseName = sanitizedFilename(projectName)
            var candidate = root.appendingPathComponent(baseName).appendingPathExtension("3105")
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = root.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("3105")
                suffix += 1
            }
            destination = candidate
        }
        let protectedData = try PatchKeyStore.encryptAtRest(data)
        try protectedData.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    static func markAsAuthorCopy(
        packageID: UUID,
        fileManager: FileManager = .default
    ) throws {
        let root = try authorCopiesRootURL(fileManager: fileManager)
        try Data().write(
            to: root.appendingPathComponent(packageID.uuidString),
            options: [.atomic, .completeFileProtection]
        )
    }

    static func isAuthorCopy(
        packageID: UUID,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let root = try? authorCopiesRootURL(fileManager: fileManager) else {
            return false
        }
        return fileManager.fileExists(
            atPath: root.appendingPathComponent(packageID.uuidString).path
        )
    }

    static func overlappingTargetPath(
        in project: PatchProject,
        excludingPackageID: UUID,
        fileManager: FileManager = .default
    ) -> String? {
        var occupied = Set<String>()
        for item in load(fileManager: fileManager) where item.id != excludingPackageID {
            guard let other = item.project else { continue }
            for rule in other.rules {
                occupied.insert(rule.bundleID + "\0" + rule.relativePath)
            }
        }
        for rule in project.rules {
            let key = rule.bundleID + "\0" + rule.relativePath
            if occupied.contains(key) {
                return rule.bundleID + "/" + rule.relativePath
            }
        }
        return nil
    }

    static func installImportedPackage(
        data: Data,
        decoded: DecodedPatchPackage,
        summary: PatchPackageSummary,
        existingURL: URL?,
        origin: PatchPackageOrigin? = nil,
        fileManager: FileManager = .default
    ) throws {
        let authorCopy = isAuthorCopy(
            packageID: summary.packageID,
            fileManager: fileManager
        )
        let previousData = try existingURL.map { try readPackage(at: $0) }
        let originURL = try originFileURL(
            packageID: summary.packageID,
            fileManager: fileManager
        )
        let previousOriginData = try? Data(contentsOf: originURL)
        var savedURL: URL?
        do {
            if let origin {
                try saveOrigin(origin, to: originURL)
            }
            savedURL = try save(
                data: data,
                projectName: decoded.project.name,
                existingURL: existingURL,
                fileManager: fileManager
            )
            if summary.schemaVersion >= 2 {
                if PatchProjectAccessPolicy.shouldMaterializeWorkspace(
                    project: decoded.project,
                    isAuthorCopy: authorCopy
                ) {
                    _ = try PatchWorkspaceService.replaceWorkspace(
                        with: decoded.project,
                        fileManager: fileManager
                    )
                } else {
                    try PatchWorkspaceService.deleteWorkspace(
                        projectID: decoded.project.id,
                        fileManager: fileManager
                    )
                }
            } else {
                try? PatchWorkspaceService.deleteWorkspace(
                    projectID: decoded.project.id,
                    fileManager: fileManager
                )
            }
        } catch {
            if let previousData, let existingURL {
                try? PatchKeyStore.encryptAtRest(previousData).write(
                    to: existingURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if let savedURL, fileManager.fileExists(atPath: savedURL.path) {
                try? fileManager.removeItem(at: savedURL)
            }
            if let previousOriginData {
                try? previousOriginData.write(
                    to: originURL,
                    options: [.atomic, .completeFileProtection]
                )
            } else if origin != nil, fileManager.fileExists(atPath: originURL.path) {
                try? fileManager.removeItem(at: originURL)
            }
            throw error
        }
    }

    static func delete(
        _ item: PatchLibraryItem,
        allowApplied: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        let backupRoot = try backupRootURL(fileManager: fileManager)
        guard allowApplied || PatchTransaction.latestReceipt(
            projectID: item.id,
            backupRoot: backupRoot,
            fileManager: fileManager
        ) == nil else {
            throw PatchPackageError.activePatchCannotBeDeleted
        }
        deleteFilesImmediately(for: item, fileManager: fileManager)
    }

    private static func deleteFilesImmediately(
        for item: PatchLibraryItem,
        fileManager: FileManager
    ) {
        if fileManager.fileExists(atPath: item.packageURL.path) {
            try? fileManager.removeItem(at: item.packageURL)
        }
        try? PatchWorkspaceService.deleteWorkspace(projectID: item.id, fileManager: fileManager)
        try? PatchKeyStore.delete(for: item.summary)
        if let originURL = try? originFileURL(
            packageID: item.id,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: originURL.path) {
            try? fileManager.removeItem(at: originURL)
        }
        if let marker = try? authorCopyMarkerURL(
            packageID: item.id,
            fileManager: fileManager
        ), fileManager.fileExists(atPath: marker.path) {
            try? fileManager.removeItem(at: marker)
        }
    }

    static func synchronizeWorkspace(
        item: PatchLibraryItem,
        fileManager: FileManager = .default
    ) throws -> PatchProject {
        guard item.summary.schemaVersion >= 2,
              item.canInspectContents,
              let baseProject = item.project,
              let contentKey = item.contentKey else {
            throw PatchPackageError.invalidProject
        }
        let workspace = try PatchWorkspaceService.ensureWorkspace(
            for: baseProject,
            fileManager: fileManager
        )
        let project = try PatchWorkspaceService.snapshot(
            baseProject: baseProject,
            workspaceURL: workspace,
            fileManager: fileManager
        )
        let original = try readPackage(at: item.packageURL)
        let updated = try PatchPackageCodec.update(
            original,
            project: project,
            contentKey: contentKey,
            schemaVersion: PatchPackageCodec.latestSchemaVersion
        )
        _ = try save(
            data: updated,
            projectName: project.name,
            existingURL: item.packageURL,
            fileManager: fileManager
        )
        return project
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }

    private static func authorCopiesRootURL(
        fileManager: FileManager
    ) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent(authorCopiesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func authorCopyMarkerURL(
        packageID: UUID,
        fileManager: FileManager
    ) throws -> URL {
        try authorCopiesRootURL(fileManager: fileManager)
            .appendingPathComponent(packageID.uuidString)
    }

    private static func originsRootURL(fileManager: FileManager) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent(originsDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func originFileURL(
        packageID: UUID,
        fileManager: FileManager
    ) throws -> URL {
        try originsRootURL(fileManager: fileManager)
            .appendingPathComponent(packageID.uuidString)
            .appendingPathExtension("plist")
    }

    private static func loadOrigin(
        packageID: UUID,
        fileManager: FileManager
    ) -> PatchPackageOrigin? {
        guard let url = try? originFileURL(
            packageID: packageID,
            fileManager: fileManager
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PropertyListDecoder().decode(PatchPackageOrigin.self, from: data)
    }

    private static func saveOrigin(
        _ origin: PatchPackageOrigin,
        to url: URL
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(origin).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
    }
}
