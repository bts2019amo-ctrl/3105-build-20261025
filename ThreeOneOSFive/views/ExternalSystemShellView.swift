import SwiftUI
import UIKit

struct ExternalSystemShellView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var keySession: IOSKeySession
    @EnvironmentObject private var patchStore: PatchProjectStore
    @StateObject private var remoteConfig = RemoteAppConfigStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue

    @State private var route: DeltaRoute = .splash
    @State private var selectedGame: DeltaGame = .freeFire
    @State private var selectedTab: ExerTab = .home
    @State private var showAnnouncement = false
    @State private var showErrorBanner = false
    @AppStorage("externalSystem.streamProofEnabled") private var streamProofEnabled = false
    @AppStorage(DeltaColors.themeKey) private var themeRaw = DeltaTheme.dark.rawValue
    @AppStorage(DeltaColors.darkModeKey) private var darkMode = true
    @AppStorage(DeltaColors.customHueKey) private var customHue = 0.76
    @State private var isScreenCaptured = UIScreen.screens.contains(where: { $0.isCaptured })
    @State private var screenshotShieldActive = false

    private var isVietnamese: Bool { languageCode == AppLanguage.vietnamese.rawValue }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.28) }

    var body: some View {
        ZStack {
            switch route {
            case .splash:
                DeltaSplashView(brandName: "EXER CHEAT", subtitle: remoteConfig.config.subtitle, logoURL: remoteConfig.config.logoUrl)
                    .transition(.opacity)
            case .selector:
                DeltaGameSelectorView(
                    selectedGame: $selectedGame,
                    languageCode: $languageCode,
                    isVietnamese: isVietnamese,
                    onEnter: { withAnimation(motion) { showAnnouncement = true } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .dashboard:
                ExerDashboardView(
                    selectedGame: $selectedGame,
                    selectedTab: $selectedTab,
                    languageCode: $languageCode,
                    showErrorBanner: $showErrorBanner,
                    isVietnamese: isVietnamese,
                    appState: appState,
                    keySession: keySession,
                    onBackToGameSelection: {
                        withAnimation(motion) {
                            selectedTab = .home
                            route = .selector
                        }
                    }
                )
                .environmentObject(remoteConfig)
                .transition(.opacity)
            }

            if showAnnouncement {
                DeltaAnnouncementView(isVietnamese: isVietnamese, config: remoteConfig.config) {
                    withAnimation(motion) {
                        showAnnouncement = false
                        route = .dashboard
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }

            if remoteConfig.config.maintenance.enabled {
                Color.black.opacity(0.96).ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                            Text(remoteConfig.config.maintenance.title.isEmpty ? "Em manuten\u{00e7}\u{00e3}o" : remoteConfig.config.maintenance.title).font(.title2.weight(.bold)).foregroundStyle(.white)
                            Text(remoteConfig.config.maintenance.message).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
                        }.padding(32)
                    }.zIndex(30)
            }

            if streamProofEnabled && (isScreenCaptured || screenshotShieldActive) {
                Color.black.ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash.fill").font(.system(size: 28, weight: .bold))
                            Text(isVietnamese ? "Conte\u{00fa}do protegido" : "Protected content").font(.headline.weight(.bold))
                        }.foregroundStyle(.white)
                    }.transition(.opacity).zIndex(20)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environmentObject(remoteConfig)
        .preferredColorScheme(.dark)
        .animation(motion, value: route)
        .animation(motion, value: showAnnouncement)
        .task {
            remoteConfig.start()
            await remoteConfig.refresh()
            guard route == .splash else { return }
            try? await Task.sleep(nanoseconds: reduceMotion ? 350_000_000 : 1_650_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(motion) { route = .selector }
        }
        .onChange(of: route) { newRoute in
            if newRoute == .dashboard { patchStore.syncNow() }
        }
        .onChange(of: selectedGame) { _ in patchStore.syncNow() }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = UIScreen.screens.contains(where: { $0.isCaptured })
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard streamProofEnabled else { return }
            screenshotShieldActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { screenshotShieldActive = false }
        }
        .task(id: streamProofEnabled) {
            while !Task.isCancelled {
                let captured = UIScreen.screens.contains(where: { $0.isCaptured })
                if captured != isScreenCaptured { isScreenCaptured = captured }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

private enum ExerTab: Hashable {
    case home, skin, clean, external
    var title: String {
        switch self {
        case .home: return "Home"
        case .skin: return "Skin"
        case .clean: return "Clean"
        case .external: return "External"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .skin: return "tshirt.fill"
        case .clean: return "bolt.fill"
        case .external: return "scope"
        }
    }
}

private enum DeltaRoute: Equatable { case splash, selector, dashboard }
private enum DeltaGame: String, CaseIterable { case freeFire, freeFireMax }

enum DeltaTheme: String, CaseIterable, Identifiable {
    case lavender, blue, emerald, red, orange, pink, cyan, gold, graphite, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var swatch: Color { Color.white }
}

struct DeltaPalette {
    let primary: Color
    let dark: Color
    let page: Color
    let ink: Color
    let muted: Color
    let card: Color
    let line: Color
    static func make(_ theme: DeltaTheme, darkMode: Bool) -> DeltaPalette {
        DeltaPalette(primary: .white, dark: Color(white: 0.15), page: .black, ink: .white.opacity(0.96), muted: .white.opacity(0.45), card: Color(red: 0.08, green: 0.08, blue: 0.09), line: .white.opacity(0.12))
    }
}

enum DeltaColors {
    static let themeKey = "externalSystem.theme"
    static let darkModeKey = "externalSystem.darkMode"
    static let customHueKey = "externalSystem.customHue"
    private static var palette: DeltaPalette { DeltaPalette.make(.dark, darkMode: true) }
    static var purple: Color { palette.primary }
    static var purpleDark: Color { palette.dark }
    static var lavender: Color { palette.page }
    static var page: Color { palette.page }
    static var ink: Color { palette.ink }
    static var muted: Color { palette.muted }
    static var card: Color { palette.card }
    static var line: Color { palette.line }
    static var isDark: Bool { true }
}

private struct ExerDashboardView: View {
    @Binding var selectedGame: DeltaGame
    @Binding var selectedTab: ExerTab
    @Binding var languageCode: String
    @Binding var showErrorBanner: Bool
    let isVietnamese: Bool
    let appState: AppState
    let keySession: IOSKeySession
    let onBackToGameSelection: () -> Void
    @EnvironmentObject private var remoteConfig: RemoteAppConfigStore
    @EnvironmentObject private var patchStore: PatchProjectStore

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("EXER CHEAT").font(.system(size: 18, weight: .black, design: .rounded)).tracking(1.2).foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("LIVE").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 12)

                HStack(spacing: 10) {
                    gamePill(title: "Free Fire", selected: selectedGame == .freeFire) { withAnimation(.easeInOut(duration: 0.18)) { selectedGame = .freeFire } }
                    gamePill(title: "FF Max", selected: selectedGame == .freeFireMax) { withAnimation(.easeInOut(duration: 0.18)) { selectedGame = .freeFireMax } }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)

                ScrollView(showsIndicators: false) {
                    Group {
                        switch selectedTab {
                        case .home: ExerHomeTab(selectedGame: selectedGame)
                        case .skin: ExerSkinTab(selectedGame: selectedGame)
                        case .clean: ExerCleanTab()
                        case .external: ExerExternalTab(selectedGame: selectedGame)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 100)
                }
            }
            ExerBottomBar(selectedTab: $selectedTab)
        }
        .preferredColorScheme(.dark)
    }

    private func gamePill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? .black : .white.opacity(0.7))
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? Color.white : Color(white: 0.12), in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct ExerBottomBar: View {
    @Binding var selectedTab: ExerTab
    private let tabs: [ExerTab] = [.home, .skin, .clean, .external]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button { withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 18, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.title).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.4))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
        }
        .padding(.bottom, 18)
        .background(Color(white: 0.06).overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5), alignment: .top).ignoresSafeArea(edges: .bottom))
    }
}

private struct ExerHomeTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let selectedGame: DeltaGame
    private var cacheItems: [PatchLibraryItem] { items(for: .cache) }
    private var avatarItems: [PatchLibraryItem] { items(for: .avatar) }
    private func items(for feature: PatchFeatureCategory) -> [PatchLibraryItem] {
        let category: PatchGameCategory = selectedGame == .freeFire ? .normal : .max
        return patchStore.items.filter { PatchProjectLibrary.category(for: $0) == category && PatchProjectLibrary.featureCategory(for: $0) == feature }
    }
    private func isApplied(_ item: PatchLibraryItem) -> Bool { DevicePatchService.latestReceipt(projectID: item.id) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedGame == .freeFire ? "FREE FIRE \u{00b7} READY" : "FREE FIRE MAX \u{00b7} READY").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                Text("Choose option").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("No option selected").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            sectionHeader("CACHE")
            VStack(spacing: 0) {
                if cacheItems.isEmpty { emptyRow("Nenhum cache dispon\u{00ed}vel") }
                else {
                    ForEach(Array(cacheItems.enumerated()), id: \.element.id) { index, item in
                        toggleRow(title: PatchProjectLibrary.displayName(for: item), isOn: isApplied(item), isLast: index == cacheItems.count - 1) {
                            if isApplied(item) { patchStore.restoreInline(item) } else { patchStore.applyInline(item) }
                        }
                    }
                }
            }.background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            sectionHeader("AVATAR")
            VStack(spacing: 0) {
                if avatarItems.isEmpty { emptyRow("Nenhum avatar dispon\u{00ed}vel") }
                else {
                    ForEach(Array(avatarItems.enumerated()), id: \.element.id) { index, item in
                        toggleRow(title: PatchProjectLibrary.displayName(for: item), isOn: isApplied(item), isLast: index == avatarItems.count - 1) {
                            if isApplied(item) { patchStore.restoreInline(item) } else { patchStore.applyInline(item) }
                        }
                    }
                }
            }.background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.padding(.top, 4)
    }
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4)).tracking(1.0).padding(.leading, 4)
    }
    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 18)
    }
    private func toggleRow(title: String, isOn: Bool, isLast: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.white : Color(white: 0.22)).frame(width: 48, height: 28)
                    Circle().fill(isOn ? Color.black : Color.white).frame(width: 22, height: 22).padding(3)
                }
            }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 16) }
        }
    }
}

private struct ExerSkinTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let selectedGame: DeltaGame
    @State private var selectedCharacter: String = "Alok"
    private var skinItems: [PatchLibraryItem] {
        let category: PatchGameCategory = selectedGame == .freeFire ? .normal : .max
        return patchStore.items.filter { PatchProjectLibrary.category(for: $0) == category && PatchProjectLibrary.featureCategory(for: $0) == .skin }
    }
    private func isApplied(_ item: PatchLibraryItem) -> Bool { DevicePatchService.latestReceipt(projectID: item.id) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CHARACTER").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4)).tracking(1.0)
            HStack(spacing: 12) {
                characterCard(name: "Alok", selected: selectedCharacter == "Alok") { selectedCharacter = "Alok" }
                characterCard(name: "Dimitri", selected: selectedCharacter == "Dimitri") { selectedCharacter = "Dimitri" }
            }
            VStack(spacing: 0) {
                if skinItems.isEmpty {
                    Text("Nenhuma skin dispon\u{00ed}vel").font(.system(size: 14)).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    ForEach(Array(skinItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if isApplied(item) { patchStore.restoreInline(item) } else { patchStore.applyInline(item) }
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.15)).frame(width: 42, height: 42)
                                    .overlay { Image(systemName: "tshirt.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5)) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(PatchProjectLibrary.displayName(for: item)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(selectedCharacter + " \u{00b7} Free Fire").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer()
                                if isApplied(item) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white) }
                            }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            if index != skinItems.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 68) }
                        }
                    }
                }
            }.background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button {
                if let item = skinItems.first(where: { !isApplied($0) }) { patchStore.applyInline(item) }
            } label: {
                Text("INJECT").font(.system(size: 15, weight: .bold)).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 50).background(Color.white, in: Capsule())
            }.buttonStyle(.plain).padding(.top, 8)
        }.padding(.top, 4)
    }
    private func characterCard(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.1)).frame(height: 110)
                    .overlay { Image(systemName: "person.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.25)) }
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.white : Color.clear, lineWidth: 2) }
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? .white : .white.opacity(0.5))
                Text("Select skins").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }.frame(maxWidth: .infinity).padding(10)
            .background(selected ? Color(white: 0.12) : Color(white: 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(.plain)
    }
}

private struct ExerCleanTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Clean ESP").font(.system(size: 20, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            Button {} label: {
                Text("Clean ESP").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }.buttonStyle(.plain)
            Spacer(minLength: 40)
        }
    }
}

private struct ExerExternalTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let selectedGame: DeltaGame
    private var externalItems: [PatchLibraryItem] {
        let category: PatchGameCategory = selectedGame == .freeFire ? .normal : .max
        return patchStore.items.filter {
            guard PatchProjectLibrary.category(for: $0) == category else { return false }
            let displayName = PatchProjectLibrary.displayName(for: $0)
            let fileName = $0.packageURL.deletingPathExtension().lastPathComponent
            return PatchProjectLibrary.featureCategory(for: $0) == .external || displayName.localizedCaseInsensitiveContains("external") || fileName.localizedCaseInsensitiveContains("external")
        }
    }
    private func isApplied(_ item: PatchLibraryItem) -> Bool { DevicePatchService.latestReceipt(projectID: item.id) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EXTERNAL").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4)).tracking(1.0).padding(.top, 4)
            VStack(spacing: 0) {
                if externalItems.isEmpty {
                    Text("Nenhum external dispon\u{00ed}vel").font(.system(size: 14)).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                } else {
                    ForEach(Array(externalItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if isApplied(item) { patchStore.restoreInline(item) } else { patchStore.applyInline(item) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(PatchProjectLibrary.displayName(for: item)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(isApplied(item) ? "Ativo" : "Pronto").font(.system(size: 11)).foregroundStyle(isApplied(item) ? Color.green : .white.opacity(0.4))
                                }
                                Spacer()
                                Text(isApplied(item) ? "CLEAR" : "START").font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(isApplied(item) ? .orange : .black)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(isApplied(item) ? Color.orange.opacity(0.2) : Color.white, in: Capsule())
                            }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            if index != externalItems.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 16) }
                        }
                    }
                }
            }.background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("TOOLS").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.4)).tracking(1.0).padding(.top, 8)
            VStack(spacing: 10) {
                toolButton("Clean Misc")
                toolButton("Reset Guest")
                toolButton("Reset Guest - Clean")
            }
        }
    }
    private func toolButton(_ title: String) -> some View {
        Button {} label: {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48)
                .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain)
    }
}

private struct DeltaSplashView: View {
    let brandName: String
    let subtitle: String
    let logoURL: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                if let logoURL, let url = URL(string: logoURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() } else { AppLogo(size: 92) }
                    }.frame(width: 92, height: 92).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).scaleEffect(pulse ? 1.05 : 0.95)
                } else {
                    AppLogo(size: 92).scaleEffect(pulse ? 1.05 : 0.95)
                }
                Text(brandName).font(.system(size: 22, weight: .black, design: .rounded)).tracking(1.3).foregroundStyle(.white)
                ProgressView().tint(.white).scaleEffect(1.15)
                Text(subtitle.isEmpty ? "Initializing EXER CHEAT..." : subtitle).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            }
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }
}

private struct DeltaGameSelectorView: View {
    @Binding var selectedGame: DeltaGame
    @Binding var languageCode: String
    let isVietnamese: Bool
    let onEnter: () -> Void
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Text("EXER CHEAT").font(.system(size: 28, weight: .black, design: .rounded)).tracking(2).foregroundStyle(.white)
                Text(isVietnamese ? "Ch\u{1ecd}n game" : "Select target game").font(.subheadline).foregroundStyle(.white.opacity(0.5)).padding(.top, 6).padding(.bottom, 30)
                VStack(spacing: 12) { gameRow(.freeFire); gameRow(.freeFireMax) }.padding(.horizontal, 24)
                Button(action: onEnter) {
                    Text(isVietnamese ? "V\u{00c0}O" : "ENTER").font(.system(size: 15, weight: .bold)).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 52).background(Color.white, in: Capsule())
                }.buttonStyle(.plain).padding(.horizontal, 24).padding(.top, 28)
                Spacer()
            }
        }
    }
    private func gameRow(_ game: DeltaGame) -> some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedGame = game } } label: {
            HStack {
                Image(game == .freeFire ? "FreeFireNormal" : "FreeFireMax").resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(game == .freeFire ? "Free Fire" : "Free Fire MAX").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                ZStack {
                    Circle().stroke(selectedGame == game ? Color.white : Color.white.opacity(0.25), lineWidth: 2).frame(width: 20, height: 20)
                    if selectedGame == game { Circle().fill(Color.white).frame(width: 10, height: 10) }
                }
            }.padding(.horizontal, 14).frame(height: 60)
            .background(selectedGame == game ? Color.white.opacity(0.12) : Color(white: 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
    }
}

private struct DeltaAnnouncementView: View {
    let isVietnamese: Bool
    let config: RemoteAppConfig
    let dismiss: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(config.brandName.isEmpty ? "EXER CHEAT" : config.brandName).font(.system(size: 22, weight: .black)).foregroundStyle(.white)
                Text(config.announcement.message.isEmpty ? (isVietnamese ? "Ch\u{00e0}o m\u{1eeb}ng!" : "Welcome!") : config.announcement.message).font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button(action: dismiss) {
                    Text(isVietnamese ? "Ti\u{1ebf}p t\u{1ee5}c" : "Continue").font(.system(size: 14, weight: .bold)).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 46).background(Color.white, in: Capsule())
                }.buttonStyle(.plain)
            }.padding(28).background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous)).padding(32)
        }
    }
}
