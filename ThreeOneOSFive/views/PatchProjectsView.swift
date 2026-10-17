import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum PatchPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "3105") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

private enum WallpaperPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "tendies") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
}

struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var draftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var store: PatchProjectStore
    @AppStorage(FeatureVisibility.cleanerStorageKey) private var cleanerEnabled = true
    @State private var showImporter = false
    @State private var showWallpaperImporter = false
    @State private var showCleaner = false
    @State private var searchText = ""
    @State private var wallpaperPackages: [WallpaperStagedPackage] = []
    @State private var wallpaperImportFeedback: WallpaperImportFeedback?
    @State private var wallpaperPendingDeletion: WallpaperStagedPackage?
    @State private var isImportingWallpapers = false
    @State private var showSimulatedWallpaperDetail = false
    @State private var simulatedWallpaperDetailGate = OneShotPresentationGate()
    @State private var selectedCategory: PatchGameCategory = PatchProjectLibrary.selectedCategory
    @State private var selectedFeature: PatchFeatureCategory = PatchProjectLibrary.selectedFeatureCategory
    @State private var showAllFeatures = false
    @State private var showGameSelection = true
    @State private var isRefreshing = false
    @State private var launchMessage: String?
    private let initialFeature: PatchFeatureCategory?
    let onOpenSettings: () -> Void
    let onOpenLogs: () -> Void

    private var filteredItems: [PatchLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { item in
            if item.packageURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard let project = item.project else { return false }
            if project.name.localizedCaseInsensitiveContains(query)
                || project.author.localizedCaseInsensitiveContains(query) {
                return true
            }
            guard item.canInspectContents else { return false }
            return project.allBundleIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
                || project.directories.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                }
                || project.rules.contains {
                    $0.relativePath.localizedCaseInsensitiveContains(query)
                        || $0.replacementFilename.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var filteredWallpaperPackages: [WallpaperStagedPackage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallpaperPackages }
        return wallpaperPackages.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasLocalContent: Bool {
        !store.items.isEmpty || !wallpaperPackages.isEmpty
    }

    private var hasSearchResults: Bool {
        !filteredItems.isEmpty || !filteredWallpaperPackages.isEmpty
    }

    private var selectedCategoryItems: [PatchLibraryItem] {
        store.items.filter {
            PatchProjectLibrary.category(for: $0) == selectedCategory
                && (showAllFeatures || PatchProjectLibrary.featureCategory(for: $0) == selectedFeature)
        }
    }

    init(
        onOpenSettings: @escaping () -> Void = {},
        onOpenLogs: @escaping () -> Void = {},
        initialFeature: PatchFeatureCategory? = nil
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenLogs = onOpenLogs
        self.initialFeature = initialFeature
        _selectedFeature = State(initialValue: initialFeature ?? PatchProjectLibrary.selectedFeatureCategory)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGlassWallpaper()
                    .ignoresSafeArea()

                if showGameSelection {
                    gameSelectionContent
                } else {
                    VStack(spacing: 0) {
                        featureMenu
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 12)

                        gameIdentityHeader
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)

                        Group {
                            if !showAllFeatures && selectedFeature == .external {
                                ExternalPanelView(
                                    store: store,
                                    item: selectedCategoryItems.first,
                                    onRequestUnlock: { item in store.requestUnlock(for: item) }
                                )
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            } else if horizontalSizeClass == .regular {
                                ScrollView(showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        sectionSummary
                                        if selectedCategoryItems.isEmpty {
                                            emptyState
                                        } else {
                                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                                                ForEach(selectedCategoryItems) { item in
                                                    itemRow(item)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                    .padding(.bottom, 24)
                                }
                            } else {
                                ScrollView(showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if !hasLocalContent && (store.isBusy || isImportingWallpapers) {
                                            loadingState
                                        } else if !hasLocalContent || selectedCategoryItems.isEmpty {
                                            emptyState
                                        } else {
                                            ForEach(selectedCategoryItems) { item in
                                                itemRow(item)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.top, 4)
                                    .padding(.bottom, 24)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        patchActionButtons
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 8)
                            .background(.ultraThinMaterial)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .alert(language.text("patch.open_game"), isPresented: Binding(
                get: { launchMessage != nil },
                set: { if !$0 { launchMessage = nil } }
            )) {
                Button(language.text("common.ok"), role: .cancel) { launchMessage = nil }
            } message: {
                Text(launchMessage ?? "")
            }
            .onChange(of: selectedCategory) { category in
                PatchProjectLibrary.setSelectedCategory(category)
            }
            .onChange(of: selectedFeature) { feature in
                PatchProjectLibrary.setSelectedFeatureCategory(feature)
                showAllFeatures = false
            }
            .onAppear {
                store.startRemoteSync()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    store.startRemoteSync()
                } else if phase == .background {
                    store.stopRemoteSync()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(showGameSelection
                        ? "Configurações"
                        : language.text(selectedCategory == .max ? "patch.ff_max" : "patch.ff_normal"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                if !showGameSelection {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showGameSelection = true
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Escolher jogo")
                    }
                }
                AppUtilityToolbar(
                    language: language,
                    onOpenSettings: onOpenSettings,
                    onOpenLogs: onOpenLogs
                )
            }
            .sheet(isPresented: $showImporter) {
                FileDocumentPicker(
                    allowedContentTypes: PatchPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: PatchPackagePickerPolicy.copiesSelectedDocument,
                    allowsMultipleSelection: false,
                    onSelection: { result in
                        showImporter = false
                        if case .success(let urls) = result, let url = urls.first {
                            store.importPackage(at: url)
                        }
                    },
                    onCancel: {
                        showImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showCleaner) {
                CleanerView()
            }
            .sheet(item: $draftCoordinator.request) { request in
                PatchProjectEditorView(
                    existingProject: nil,
                    passwordIsProtected: false,
                    initialDraft: request.draft
                ) { project, password in
                    store.create(project: project, password: password)
                    draftCoordinator.clear()
                }
            }
            .sheet(isPresented: $showWallpaperImporter) {
                FileDocumentPicker(
                    allowedContentTypes: WallpaperPackagePickerPolicy.allowedContentTypes,
                    copiesSelectedDocument: true,
                    allowsMultipleSelection: true,
                    onSelection: { result in
                        showWallpaperImporter = false
                        if case .success(let urls) = result, !urls.isEmpty {
                            importWallpaperPackages(urls)
                        }
                    },
                    onCancel: {
                        showWallpaperImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .alert(item: $wallpaperImportFeedback) { feedback in
                Alert(
                    title: Text(language.text(feedback.titleKey)),
                    message: Text(feedback.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
            .alert(item: $wallpaperPendingDeletion) { package in
                Alert(
                    title: Text(language.text("wallpaper.delete_title")),
                    message: Text(language.text(
                        "wallpaper.delete_message",
                        package.displayName
                    )),
                    primaryButton: .destructive(
                        Text(language.text("common.delete"))
                    ) {
                        deleteWallpaperPackage(package)
                    },
                    secondaryButton: .cancel(Text(language.text("common.cancel")))
                )
            }
            .onAppear {
                reloadWallpaperPackages()
                consumeExternalImport()
#if targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains(
                    "--simulate-wallpaper-detail"
                ), !wallpaperPackages.isEmpty,
                   simulatedWallpaperDetailGate.claim() {
                    DispatchQueue.main.async {
                        showSimulatedWallpaperDetail = true
                    }
                }
#endif
            }
            .navigationDestination(isPresented: $showSimulatedWallpaperDetail) {
                if let package = wallpaperPackages.first {
                    InstalledWallpaperPackageDetailView(
                        package: package,
                        onApplied: reloadWallpaperPackages
                    )
                }
            }
            .onChange(of: draftCoordinator.importRequest?.id) { _ in
                consumeExternalImport()
            }
        }
    }

    private var gameSelectionContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                Spacer(minLength: 34)

                AppLogo(size: 76)
                    .padding(.bottom, 14)

                Text(language.text("brand.external_system"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(language.text("patch.choose_game"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)

                VStack(spacing: 14) {
                    gameSelectionCard(
                        category: .max,
                        title: "Free Fire MAX",
                        subtitle: "Abrir funções"
                    )
                    gameSelectionCard(
                        category: .normal,
                        title: "Free Fire Normal",
                        subtitle: "Abrir funções"
                    )
                }
                .padding(.top, 28)
                .padding(.horizontal, 18)

                Text(language.text("patch.assets_notice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                    .padding(.horizontal, 24)

                Spacer(minLength: 48)
            }
            .frame(maxWidth: .infinity)
        }
        .dynamicTypeSize(.large)
    }

    private func gameSelectionCard(
        category: PatchGameCategory,
        title: String,
        subtitle: String
    ) -> some View {
        Button {
            selectedCategory = category
            PatchProjectLibrary.setSelectedCategory(category)
            showAllFeatures = false
            withAnimation(.easeInOut(duration: 0.22)) {
                showGameSelection = false
            }
        } label: {
            HStack(spacing: 14) {
                Image(category == .max ? "FreeFireMax" : "FreeFireNormal")
                    .resizable()
                    .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.075, green: 0.075, blue: 0.085), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func consumeExternalImport() {
        guard let request = draftCoordinator.importRequest else { return }
        draftCoordinator.clearImport()
        store.importPackage(from: request.source)
    }

    private func wallpaperRow(_ package: WallpaperStagedPackage) -> some View {
        HStack(spacing: 12) {
            AppRowIcon(systemName: wallpaperSymbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                InstalledContentKindBadge(kind: .wallpaper, language: language)
                Text(language.text(
                    "wallpaper.package_summary",
                    Int64(package.payload.descriptors.count),
                    ByteCountFormatter.string(
                        fromByteCount: package.payload.totalBytes,
                        countStyle: .file
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var cleanerRow: some View {
        Button {
            showCleaner = true
        } label: {
            HStack(spacing: 12) {
                AppRowIcon(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("tab.cleaner"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(language.text("repository.cleaner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var wallpaperSymbol: String {
        if #available(iOS 18.0, *) {
            return "photo.on.rectangle.angled.fill"
        }
        return "photo.fill.on.rectangle.fill"
    }

    private func reloadWallpaperPackages() {
        wallpaperPackages = WallpaperPackageStore.packages()
    }

    private func deleteWallpaperPackage(_ package: WallpaperStagedPackage) {
        do {
            try WallpaperPackageStore.delete(package)
            reloadWallpaperPackages()
        } catch {
            wallpaperImportFeedback = WallpaperImportFeedback(
                titleKey: "wallpaper.operation_failed",
                message: wallpaperErrorMessage(error)
            )
        }
    }

    private func importWallpaperPackages(_ urls: [URL]) {
        guard !isImportingWallpapers else { return }
        isImportingWallpapers = true
        DispatchQueue.global(qos: .userInitiated).async {
            var imported = 0
            var failures: [String] = []
            for url in urls {
                do {
                    _ = try WallpaperPackageStore.importPackage(from: url)
                    imported += 1
                    log("wallpaper: staged \(url.lastPathComponent)")
                } catch {
                    failures.append(
                        "\(url.lastPathComponent): \(wallpaperErrorMessage(error))"
                    )
                    log("wallpaper: import rejected \(url.lastPathComponent)")
                }
            }
            DispatchQueue.main.async {
                isImportingWallpapers = false
                reloadWallpaperPackages()
                wallpaperImportFeedback = WallpaperImportFeedback(
                    titleKey: failures.isEmpty
                        ? "wallpaper.import_done_title"
                        : "wallpaper.import_result_title",
                    message: failures.isEmpty
                        ? language.text(
                            "wallpaper.import_done_message",
                            Int64(imported)
                        )
                        : failures.joined(separator: "\n")
                )
            }
        }
    }

    private func wallpaperErrorMessage(_ error: Error) -> String {
        if let wallpaperError = error as? WallpaperLabError {
            return language.text(wallpaperError.localizationKey)
        }
        return language.text("wallpaper.error.unknown")
    }

    @ViewBuilder
    private func itemRow(_ item: PatchLibraryItem) -> some View {
        if item.isLocked {
            Button { store.requestUnlock(for: item) } label: {
                HStack(spacing: 14) {
                    remotePatchIcon(for: item)
                    Text(language.text("patch.locked_project"))
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Color(red: 0.075, green: 0.075, blue: 0.085), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                remotePatchIcon(for: item)
                Text(PatchProjectLibrary.localizedDisplayName(for: item, language: language))
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PatchActivationToggle(store: store, item: item)
                    .frame(width: 56, height: 32)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color(red: 0.075, green: 0.075, blue: 0.085), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
            }
        }
    }

    @ViewBuilder
    private func remotePatchIcon(for item: PatchLibraryItem) -> some View {
        if let iconURL = PatchProjectLibrary.remoteIconURL(for: item.id) {
            AsyncImage(url: iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    AppRowIcon(systemName: "shippingbox.fill", symbolSize: 22, frameSize: 58)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            }
            .transition(.scale(scale: 0.88).combined(with: .opacity))
        } else {
            AppRowIcon(systemName: "shippingbox.fill", symbolSize: 22, frameSize: 58)
        }
    }

    private var patchActionButtons: some View {
        VStack(spacing: 10) {
            Button {
                guard !isRefreshing else { return }
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    isRefreshing = true
                }
                store.syncNow()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        isRefreshing = false
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    Text(language.text(isRefreshing ? "patch.refreshing" : "patch.refresh"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Button(action: openSelectedGame) {
                Label(language.text("patch.open_game"), systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.75), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private func openSelectedGame() {
        let scheme = selectedCategory == .max ? "freefiremax" : "freefire"
        guard let url = URL(string: "\(scheme)://") else { return }
        guard UIApplication.shared.canOpenURL(url) else {
            launchMessage = language.text(
                selectedCategory == .max
                    ? "patch.game_not_installed_max"
                    : "patch.game_not_installed_normal"
            )
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            UIApplication.shared.open(url)
        }
    }

    private var featureTitle: String {
        language.text("patch.feature." + selectedFeature.rawValue)
    }

    private var sectionSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(featureTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(selectedCategoryItems.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(minWidth: 28, minHeight: 28)
                .background(Color.white.opacity(0.1), in: Circle())
                .accessibilityLabel("\(selectedCategoryItems.count) patches")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var gameIdentityHeader: some View {
        HStack(spacing: 12) {
            Image(selectedCategory == .max ? "FreeFireMax" : "FreeFireNormal")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: AppTheme.accent.opacity(0.35), radius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(language.text(selectedCategory == .max ? "patch.ff_max" : "patch.ff_normal"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(language.text("patch.title"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
        }
        .contentTransition(.opacity)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: selectedCategory)
    }

    private var categorySegmentedControl: some View {
        HStack(spacing: 3) {
            categoryButton(.normal, titleKey: "patch.ff_normal")
            categoryButton(.max, titleKey: "patch.ff_max")
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 0.7))
    }

    private func categoryButton(_ category: PatchGameCategory, titleKey: String) -> some View {
        Button { selectedCategory = category } label: {
            Text(language.text(titleKey))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(selectedCategory == category ? .black : .secondary)
                .frame(minWidth: 82, maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selectedCategory == category ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var featureMenu: some View {
        Menu {
            Button { selectedFeature = .cache } label: { menuChoice("patch.feature.cache", selectedFeature == .cache) }
            Button { selectedFeature = .avatar } label: { menuChoice("patch.feature.avatar", selectedFeature == .avatar) }
            Button { selectedFeature = .hologram } label: { menuChoice("patch.feature.hologram", selectedFeature == .hologram) }
            Button { selectedFeature = .external } label: { menuChoice("patch.feature.external", selectedFeature == .external) }
            Button { selectedFeature = .skin } label: { menuChoice("patch.feature.skin", selectedFeature == .skin) }
        } label: {
            Label(featureTitle, systemImage: "slider.horizontal.3")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 0.7))
        }
    }

    private func menuChoice(_ key: String, _ selected: Bool) -> some View {
        HStack {
            Text(language.text(key))
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("installed.empty_title"))
                .font(.headline)
            Text(language.text("installed.empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(language.text("installed.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("patch.search_empty"))
                .font(.headline)
            Text(language.text("patch.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private enum ExternalPanelTab: String, CaseIterable, Identifiable {
    case aim
    case esp
    case general
    case xray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aim: return "MIRA"
        case .esp: return "ESP"
        case .general: return "GERAL"
        case .xray: return "RAIO-X"
        }
    }

    func localizedTitle(language: AppLanguage) -> String {
        switch self {
        case .aim: return language.text("external.aimbot")
        case .esp: return language.text("external.player_esp")
        case .general: return language.text("external.general")
        case .xray: return language.text("external.xray")
        }
    }

    var icon: String {
        switch self {
        case .aim: return "scope"
        case .esp: return "eye.fill"
        case .general: return "slider.horizontal.3"
        case .xray: return "figure.stand"
        }
    }
}

struct ExternalPanelView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let item: PatchLibraryItem?
    let onRequestUnlock: (PatchLibraryItem) -> Void

    @State private var selectedTab: ExternalPanelTab = .aim
    @State private var aimOnFire = true
    @State private var prioritizeHead = true
    @State private var fineAim = false
    @State private var quickHeal = false
    @State private var boxESP = true
    @State private var healthESP = false
    @State private var nameESP = false
    @State private var distanceESP = false
    @State private var directionESP = true
    @State private var markEnemies = false
    @State private var shotInterval = 0.85
    @State private var effectDistance = 120.0
    @State private var isWorking = false
    @State private var actionMessage: String?

    private var receipt: PatchTransactionReceipt? {
        guard let item else { return nil }
        return DevicePatchService.latestReceipt(projectID: item.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 14) {
                sidebar
                content
            }
            footer
        }
        .padding(14)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.red.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .alert(language.text("external.title"), isPresented: Binding(
            get: { actionMessage != nil },
            set: { if !$0 { actionMessage = nil } }
        )) {
                Button(language.text("common.ok"), role: .cancel) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppLogo(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("external.title"))
                    .font(.headline.weight(.black))
                    .tracking(1.2)
                Text(language.text("external.panel"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.gray)
                    .tracking(1.3)
            }
            Spacer()
            Label(language.text("external.online"), systemImage: "circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 14)
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            ForEach(ExternalPanelTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.localizedTitle(language: language))
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(selectedTab == tab ? .black : .gray)
                    .frame(width: 58, height: 58)
                    .background(selectedTab == tab ? Color.white : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text(selectedTab == .aim ? language.text("external.aimbot") : selectedTab == .esp ? language.text("external.player_esp") : selectedTab.localizedTitle(language: language))
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                if selectedTab == .aim {
                    toggleRow(language.text("external.aim_fire"), icon: "scope", isOn: $aimOnFire)
                    toggleRow(language.text("external.prioritize_head"), icon: "person.crop.circle.badge.target", isOn: $prioritizeHead)
                    toggleRow(language.text("external.fine_aim"), icon: "keyboard", isOn: $fineAim)
                    toggleRow(language.text("external.quick_heal"), icon: "cross.case.fill", isOn: $quickHeal)
                    sliderCard(language.text("external.shot_interval"), icon: "bolt.fill", value: $shotInterval, range: 0.65...1.0, labels: ["NORMAL", "90%", "85%", "75%", "65%"])
                } else if selectedTab == .esp {
                    toggleRow(language.text("external.box"), icon: "square", isOn: $boxESP)
                    toggleRow(language.text("external.health"), icon: "heart.fill", isOn: $healthESP)
                    toggleRow(language.text("external.name"), icon: "person.text.rectangle", isOn: $nameESP)
                    toggleRow(language.text("external.distance"), icon: "ruler", isOn: $distanceESP)
                    toggleRow(language.text("external.direction"), icon: "location.north.fill", isOn: $directionESP)
                    toggleRow(language.text("external.mark_enemies"), icon: "figure.stand", isOn: $markEnemies)
                    sliderCard(language.text("external.effect_distance"), icon: "ruler.fill", value: $effectDistance, range: 20...240, labels: ["20 m", "80 m", "120 m", "180 m", "240 m"])
                } else {
                    toggleRow(language.text("external.safe_mode"), icon: "shield.fill", isOn: .constant(true))
                    toggleRow(language.text("external.optimization"), icon: "wand.and.stars", isOn: .constant(true))
                    toggleRow(language.text("external.session_protection"), icon: "lock.shield.fill", isOn: .constant(true))
                    Text(language.text("external.select_aim_esp"))
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .padding(.top, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { resetControls() } label: {
                Label(language.text("external.clear_data"), systemImage: "trash.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button { applySelectedPatch() } label: {
                Label(language.text(isWorking ? "external.applying" : "external.start"), systemImage: "play.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || item == nil)
            .opacity(item == nil ? 0.45 : 1)
        }
        .padding(.top, 14)
    }

    private func toggleRow(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(ReferenceToggleStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 0.6))
    }

    private func sliderCard(_ title: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Slider(value: value, in: range)
                .tint(.white)
            HStack {
                ForEach(labels, id: \.self) { label in
                    Text(label).font(.caption2).foregroundStyle(.gray)
                    if label != labels.last { Spacer() }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func resetControls() {
        aimOnFire = false
        prioritizeHead = false
        fineAim = false
        quickHeal = false
        boxESP = false
        healthESP = false
        nameESP = false
        distanceESP = false
        directionESP = false
        markEnemies = false
        shotInterval = 1.0
        effectDistance = 20
        restoreSelectedPatch()
    }

    private func applySelectedPatch() {
        guard let item, let project = item.project, receipt == nil else {
            if receipt != nil { actionMessage = "O patch External já está aplicado." }
            return
        }
        if item.isLocked {
            onRequestUnlock(item)
            return
        }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let synchronized = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : project
                _ = try DevicePatchService.apply(project: synchronized)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func restoreSelectedPatch() {
        guard receipt != nil else { return }
        restore(allowChangedTargets: true)
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: allowChangedTargets)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct WallpaperImportFeedback: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private struct PatchProjectRow: View {
    let item: PatchLibraryItem
    let language: AppLanguage

    var body: some View {
        let isApplied = DevicePatchService.latestReceipt(projectID: item.id) != nil
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isApplied ? Color.green : Color.clear)
                .frame(width: 3)
            if PatchProjectLibrary.featureCategory(for: item) == .skin,
               let iconURL = PatchProjectLibrary.remoteIconURL(for: item.id) {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        AppRowIcon(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                AppRowIcon(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.isLocked ? language.text("patch.locked_project") : PatchProjectLibrary.localizedDisplayName(for: item, language: language))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let author = item.project?.author, !author.isEmpty {
                    Text(language.text("patch.by_author", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(language.text("patch.feature." + PatchProjectLibrary.featureCategory(for: item).rawValue))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isApplied ? Color.green : Color.white.opacity(0.32))
                        .frame(width: 6, height: 6)
                    if isApplied {
                        Text("ATIVO")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    }
                }
                if item.summary.isPasswordProtected || item.project?.isPrivate == true {
                    HStack(spacing: 6) {
                        if item.summary.isPasswordProtected {
                            Image(systemName: "key.fill")
                                .accessibilityLabel(language.text("patch.password_protected"))
                        }
                        if item.project?.isPrivate == true {
                            Image(systemName: "eye.slash.fill")
                                .foregroundStyle(AppTheme.accent)
                                .accessibilityLabel(language.text("patch.private"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        if item.isLocked {
            return language.text("patch.tap_to_unlock")
        }
        if item.project?.isPrivate == true, !item.isAuthorCopy {
            return language.text("patch.private_received")
        }
        return language.text(
            item.summary.schemaVersion >= 2
                ? "patch.workspace_items_count"
                : "patch.rules_count",
            Int64((item.project?.rules.count ?? 0) + (item.project?.directories.count ?? 0))
        )
    }
}

private struct PatchActivationToggle: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let item: PatchLibraryItem
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?
    @State private var actionPulse = false

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: item.id)
    }

    var body: some View {
        Group {
            if isWorking {
                ProgressView()
                    .frame(width: 32, height: 32)
            } else {
                Toggle(isOn: activationBinding) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(ReferenceToggleStyle())
                .accessibilityLabel(language.text("patch.toggle"))
            }
        }
        .frame(width: 56, height: 32)
        .scaleEffect(actionPulse ? 1.08 : 1)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.accent.opacity(actionPulse ? 0.75 : 0), lineWidth: 2)
                .blur(radius: actionPulse ? 0.2 : 0)
        }
        .animation(.easeOut(duration: 0.28), value: actionPulse)
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private var activationBinding: Binding<Bool> {
        Binding(
            get: { receipt != nil },
            set: { isEnabled in
                guard !isWorking else { return }
                if isEnabled {
                    guard receipt == nil else { return }
                    apply()
                } else {
                    guard receipt != nil else { return }
                    prepareRestore()
                }
            }
        )
    }

    private func apply() {
        guard let project = item.project, receipt == nil else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let synchronizedProject = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : project
                _ = try DevicePatchService.apply(project: synchronizedProject)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    withAnimation { actionPulse = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                        withAnimation { actionPulse = false }
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func prepareRestore() {
        restore(allowChangedTargets: true)
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt, allowChangedTargets: allowChangedTargets)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    withAnimation { actionPulse = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                        withAnimation { actionPulse = false }
                    }
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func privateErrorKey(for error: PatchPackageError) -> String {
        guard item.project?.isPrivate == true, !item.isAuthorCopy else { return error.localizationKey }
        return "patch.error.private_operation"
    }

    private func privateErrorArgument(for error: PatchPackageError) -> String? {
        guard item.project?.isPrivate == true, !item.isAuthorCopy else { return error.localizationArgument }
        return nil
    }
}

private enum InstalledContentKind {
    case patch
    case wallpaper

    var localizationKey: String {
        switch self {
        case .patch: return "installed.kind.patch"
        case .wallpaper: return "installed.kind.wallpaper"
        }
    }

    var systemImage: String {
        switch self {
        case .patch: return "shippingbox.fill"
        case .wallpaper: return "photo.fill"
        }
    }
}

private struct InstalledContentKindBadge: View {
    let kind: InstalledContentKind
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .accessibilityHidden(true)
            Text(language.text(kind.localizationKey))
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(AppTheme.accent.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    let request: PatchPasswordRequest
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in
                            store.clearUnlockError()
                        }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if let origin = request.origin {
                        Text(language.text(
                            "patch.password_repo_contact",
                            origin.repositoryName
                        ))
                    } else {
                        Text(language.text("patch.password_once_message"))
                    }
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

private struct PatchStorePresentationModifier: ViewModifier {
    @ObservedObject var store: PatchProjectStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.passwordRequest, onDismiss: store.cancelUnlock) { request in
                PatchUnlockView(store: store, request: request)
            }
    }
}

extension View {
    func patchStorePresentation(_ store: PatchProjectStore) -> some View {
        modifier(PatchStorePresentationModifier(store: store))
    }
}

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showResetConfirmation = false
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?
    @State private var shareRequest: PatchShareRequest?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: projectID)
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                Section(language.text("patch.information")) {
                    if !project.author.isEmpty {
                        patchInfoRow(
                            label: language.text("patch.author"),
                            value: project.author
                        )
                    }
                    patchInfoRow(label: language.text("patch.privacy")) {
                        Label(
                            language.text(project.isPrivate
                                ? "patch.private"
                                : "patch.public"),
                            systemImage: project.isPrivate
                                ? "eye.slash.fill"
                                : "eye"
                        )
                        .foregroundStyle(project.isPrivate ? AppTheme.accent : Color.secondary)
                    }
                    if let origin = item.origin {
                        patchInfoRow(
                            label: language.text("repository.source"),
                            value: origin.repositoryName
                        )
                    }
                }

                if project.isPrivate && !item.canInspectContents {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                            Text(language.text("patch.private_hidden_title"))
                                .font(.headline)
                            Text(language.text("patch.private_hidden_message"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else if isWorkspaceProject {
                    Section {
                        ForEach(project.allBundleIdentifiers, id: \.self) { bundleID in
                            Label {
                                Text(bundleID)
                                    .font(.subheadline.monospaced())
                            } icon: {
                                Image(systemName: "app.dashed")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        LabeledContent(language.text("patch.files")) {
                            Text("\(project.rules.count)")
                        }
                        LabeledContent(language.text("patch.folders")) {
                            Text("\(project.directories.count)")
                        }
                        if let workspaceURL = item.workspaceURL {
                            NavigationLink {
                                FileBrowserView(
                                    containerPath: workspaceURL.path,
                                    title: project.name,
                                    bundleID: nil
                                )
                            } label: {
                                Label(
                                    language.text("patch.open_workspace"),
                                    systemImage: "folder"
                                )
                            }
                        }
                    } header: {
                        Text(language.text("patch.workspace"))
                    } footer: {
                        Text(language.text("patch.workspace_detail_footer"))
                    }
                } else {
                    Section {
                        ForEach(project.rules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                HStack(spacing: 10) {
                                    ruleSummary(rule)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(language.text("patch.edit_rule_hint"))
                        }
                    } header: {
                        Text(language.text("patch.rules"))
                    } footer: {
                        Text(language.text("patch.legacy_footer"))
                    }
                }

                Section(language.text("patch.password")) {
                    HStack(spacing: 12) {
                        Image(systemName: item.summary.isPasswordProtected ? "lock.fill" : "lock.open")
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 24)
                        Text(language.text(item.summary.isPasswordProtected
                            ? "patch.password_locked"
                            : "patch.no_password"))
                            .font(.subheadline)
                    }
                }

                Section {
                    Toggle(isOn: patchActivationBinding) {
                        Label(
                            language.text("patch.toggle"),
                            systemImage: "checkmark.shield.fill"
                        )
                    }
                    .disabled(isWorking)

                    if receipt != nil {
                        Button {
                            showResetConfirmation = true
                        } label: {
                            actionLabel("patch.reset", systemImage: "arrow.counterclockwise.circle")
                        }
                        .disabled(isWorking)

                        Button(role: .destructive) {
                            prepareRestore()
                        } label: {
                            actionLabel("patch.restore", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking)
                    }

                    Button(action: prepareExport) {
                        actionLabel("patch.export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isWorking)
                } footer: {
                    Text(language.text("patch.apply_footer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.project?.name ?? language.text("patch.title"))
        .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject, item?.canInspectContents == true {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let item, let project = item.project {
                PatchProjectEditorView(
                    existingProject: project,
                    passwordIsProtected: item.summary.isPasswordProtected
                ) { updatedProject, _ in
                    store.update(project: updatedProject)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PatchRuleEditorView(rule: rule) { updatedRule in
                updateRule(updatedRule)
            }
        }
        .confirmationDialog(
            language.text("patch.reset_confirm_title"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.reset"), role: .destructive) { resetToAppliedState() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.reset_confirm_message"))
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .sheet(item: $shareRequest) { request in
            PatchActivityView(items: [request.url])
                .ignoresSafeArea()
        }
    }

    private func actionLabel(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var patchActivationBinding: Binding<Bool> {
        Binding(
            get: { receipt != nil },
            set: { isEnabled in
                guard !isWorking else { return }
                if isEnabled {
                    guard receipt == nil else { return }
                    apply()
                } else {
                    guard receipt != nil else { return }
                    prepareRestore()
                }
            }
        )
    }

    private func patchInfoRow(
        label: String,
        value: String
    ) -> some View {
        patchInfoRow(label: label) {
            Text(value)
                .foregroundStyle(.primary)
        }
    }

    private func patchInfoRow<Content: View>(
        label: String,
        @ViewBuilder value: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }

    private func ruleSummary(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.bundleID)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(rule.replacementFilename, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func updateRule(_ updatedRule: PatchRule) {
        guard var project = item?.project,
              let index = project.rules.firstIndex(where: { $0.id == updatedRule.id }) else {
            return
        }
        project.rules[index] = updatedRule
        project.updatedAt = Date()
        do {
            try PatchPackageCodec.validate(project)
            store.update(project: project)
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: error.localizationKey,
                messageArgument: error.localizationArgument
            )
        } catch {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: "patch.error.invalid_project"
            )
        }
    }

    private func apply() {
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let project = item.summary.schemaVersion >= 2 && item.canInspectContents
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func prepareExport() {
        guard let item else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                if item.summary.schemaVersion >= 2, item.canInspectContents {
                    _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                }
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    shareRequest = PatchShareRequest(url: item.packageURL)
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.invalid_project"
                    )
                }
            }
        }
    }

    private func prepareRestore() {
        restore(allowChangedTargets: true)
    }

    private func restore(allowChangedTargets: Bool) {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(
                    receipt: receipt,
                    allowChangedTargets: allowChangedTargets
                )
                await MainActor.run {
                    isWorking = false
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }

    private func resetToAppliedState() {
        guard let receipt, let project = item?.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.resetToAppliedState(
                    receipt: receipt,
                    project: project
                )
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.done",
                        messageKey: "patch.reset_message"
                    )
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: privateErrorKey(for: error),
                        messageArgument: privateErrorArgument(for: error)
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: "patch.error.reset"
                    )
                }
            }
        }
    }

    private func privateErrorKey(for error: PatchPackageError) -> String {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationKey
        }
        return "patch.error.private_operation"
    }

    private func privateErrorArgument(for error: PatchPackageError) -> String? {
        guard item?.project?.isPrivate == true,
              item?.isAuthorCopy == false else {
            return error.localizationArgument
        }
        return nil
    }
}

private struct PatchShareRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PatchActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
