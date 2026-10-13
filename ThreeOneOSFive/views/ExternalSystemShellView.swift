import SwiftUI
import UIKit

struct ExternalSystemShellView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var keySession: IOSKeySession
    @EnvironmentObject private var patchStore: PatchProjectStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue

    @State private var route: DeltaRoute = .splash
    @State private var selectedGame: DeltaGame = .freeFire
    @State private var selectedTab: DeltaTab = .dashboard
    @State private var showAnnouncement = false
    @State private var showErrorBanner = false
    @AppStorage("externalSystem.streamProofEnabled") private var streamProofEnabled = false
    @AppStorage(DeltaColors.themeKey) private var themeRaw = DeltaTheme.lavender.rawValue
    @State private var isScreenCaptured = UIScreen.screens.contains(where: { $0.isCaptured })
    @State private var screenshotShieldActive = false

    private var isVietnamese: Bool { languageCode == AppLanguage.vietnamese.rawValue }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.28) }

    var body: some View {
        ZStack {
            switch route {
            case .splash:
                DeltaSplashView()
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
                DeltaDashboardView(
                    selectedGame: $selectedGame,
                    selectedTab: $selectedTab,
                    languageCode: $languageCode,
                    showErrorBanner: $showErrorBanner,
                    isVietnamese: isVietnamese,
                    appState: appState,
                    keySession: keySession
                )
                .transition(.opacity)
            }

            if showAnnouncement {
                DeltaAnnouncementView(isVietnamese: isVietnamese) {
                    withAnimation(motion) {
                        showAnnouncement = false
                        route = .dashboard
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }

            if streamProofEnabled && (isScreenCaptured || screenshotShieldActive) {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 28, weight: .bold))
                            Text(isVietnamese ? "Conteúdo protegido" : "Protected content")
                                .font(.headline.weight(.bold))
                        }
                        .foregroundStyle(.white)
                    }
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .background(DeltaColors.page.ignoresSafeArea())
        .overlay(Color.clear.frame(width: 0, height: 0).id(themeRaw))
        .animation(motion, value: route)
        .animation(motion, value: showAnnouncement)
        .task {
            guard route == .splash else { return }
            try? await Task.sleep(nanoseconds: reduceMotion ? 350_000_000 : 1_650_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(motion) { route = .selector }
        }
        .onChange(of: route) { newRoute in
            if newRoute == .dashboard {
                patchStore.syncNow()
            }
        }
        .onChange(of: selectedGame) { _ in
            patchStore.syncNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = UIScreen.screens.contains(where: { $0.isCaptured })
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard streamProofEnabled else { return }
            screenshotShieldActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                screenshotShieldActive = false
            }
        }
        .task(id: streamProofEnabled) {
            // The notification is not delivered consistently across iOS versions;
            // polling keeps the shield active during recording and mirroring.
            while !Task.isCancelled {
                let captured = UIScreen.screens.contains(where: { $0.isCaptured })
                if captured != isScreenCaptured {
                    isScreenCaptured = captured
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

private enum DeltaRoute: Equatable { case splash, selector, dashboard }
private enum DeltaGame: String, CaseIterable { case freeFire, freeFireMax }
private enum DeltaTab: String, CaseIterable { case dashboard, cache, avatar, hologram, external, skin, settings
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cache: return "Cache"
        case .avatar: return "Avatar"
        case .hologram: return "Hologram"
        case .external: return "External"
        case .skin: return "Skin"
        case .settings: return "Settings"
        }
    }
    var vietnameseTitle: String {
        switch self {
        case .dashboard: return "Trang chủ"
        case .cache: return "Cache"
        case .avatar: return "Avatar"
        case .hologram: return "Hologram"
        case .external: return "External"
        case .skin: return "Skin"
        case .settings: return "Cài đặt"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "house.fill"
        case .cache: return "externaldrive.fill"
        case .avatar: return "person.crop.circle.fill"
        case .hologram: return "wand.and.stars"
        case .external: return "scope"
        case .skin: return "tshirt.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum DeltaTheme: String, CaseIterable, Identifiable {
    case lavender, blue, emerald, red, orange, pink, cyan, gold, graphite, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lavender: return "Lavanda"
        case .blue: return "Azul"
        case .emerald: return "Esmeralda"
        case .red: return "Vermelho"
        case .orange: return "Laranja"
        case .pink: return "Rosa"
        case .cyan: return "Ciano"
        case .gold: return "Dourado"
        case .graphite: return "Grafite"
        case .dark: return "Dark"
        }
    }
    var swatch: Color {
        switch self {
        case .lavender: return Color(red: 0.53, green: 0.18, blue: 0.86)
        case .blue: return Color(red: 0.10, green: 0.38, blue: 0.90)
        case .emerald: return Color(red: 0.03, green: 0.55, blue: 0.39)
        case .red: return Color(red: 0.82, green: 0.12, blue: 0.20)
        case .orange: return Color(red: 0.93, green: 0.38, blue: 0.08)
        case .pink: return Color(red: 0.87, green: 0.16, blue: 0.48)
        case .cyan: return Color(red: 0.00, green: 0.52, blue: 0.70)
        case .gold: return Color(red: 0.72, green: 0.47, blue: 0.04)
        case .graphite: return Color(red: 0.22, green: 0.25, blue: 0.31)
        case .dark: return Color(red: 0.08, green: 0.09, blue: 0.12)
        }
    }
}

private struct DeltaPalette {
    let primary: Color
    let dark: Color
    let page: Color
    let ink: Color
    let muted: Color
    let card: Color

    static func make(_ theme: DeltaTheme) -> DeltaPalette {
        let primary = theme.swatch
        switch theme {
        case .dark, .graphite:
            return DeltaPalette(primary: primary, dark: primary.opacity(0.72), page: Color(red: 0.09, green: 0.10, blue: 0.14), ink: .white, muted: Color.white.opacity(0.62), card: Color(red: 0.14, green: 0.15, blue: 0.20).opacity(0.98))
        default:
            return DeltaPalette(primary: primary, dark: primary.opacity(0.72), page: Color.white.opacity(0.94), ink: Color(red: 0.10, green: 0.08, blue: 0.20), muted: Color(red: 0.40, green: 0.42, blue: 0.50), card: Color.white.opacity(0.96))
        }
    }
}

private enum DeltaColors {
    static let themeKey = "externalSystem.theme"
    private static var palette: DeltaPalette {
        DeltaPalette.make(DeltaTheme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .lavender)
    }
    static var purple: Color { palette.primary }
    static var purpleDark: Color { palette.dark }
    static var lavender: Color { palette.page }
    static var page: Color { palette.page }
    static var ink: Color { palette.ink }
    static var muted: Color { palette.muted }
    static var card: Color { palette.card }
}

private struct DeltaSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var loadingIndex = 0
    private let messages = ["Initializing EXTERNAL SYSTEM Core...", "Loading Injector Engine...", "Preparing dashboard..."]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DeltaColors.page, Color(red: 0.93, green: 0.89, blue: 0.99), DeltaColors.page],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                AppLogo(size: 92)
                    .scaleEffect(pulse ? 1.05 : 0.95)
                    .shadow(color: DeltaColors.purple.opacity(0.35), radius: pulse ? 24 : 10)

                Text("EXTERNAL SYSTEM")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(DeltaColors.ink)

                ProgressView()
                    .tint(DeltaColors.purple)
                    .scaleEffect(1.15)

                Text(messages[loadingIndex])
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DeltaColors.muted)
                    .id(loadingIndex)
                    .transition(.opacity)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
                withAnimation(.easeInOut(duration: 0.3)) { loadingIndex = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                    withAnimation(.easeInOut(duration: 0.3)) { loadingIndex = 2 }
                }
            }
        }
    }
}

private struct DeltaGameSelectorView: View {
    @Binding var selectedGame: DeltaGame
    @Binding var languageCode: String
    let isVietnamese: Bool
    let onEnter: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            DeltaColors.page.ignoresSafeArea()
            VStack(spacing: 0) {
                DeltaHeader(selectedGame: .constant(.freeFire), showEye: false, showBack: false, onBack: {})
                    .padding(.top, 7)
                    .padding(.horizontal, 18)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        AppLogo(size: 68)
                            .padding(.top, 17)
                        Text("EXTERNAL SYSTEM")
                            .font(.system(size: 21, weight: .black, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(DeltaColors.ink)
                        Text(isVietnamese ? "Trình Thiết Kế & Quản Lý Bộ Quản" : "All-in-One Game Loader & Injector")
                            .font(.caption)
                            .foregroundStyle(DeltaColors.muted)

                        DeltaCard {
                            HStack {
                                Label(isVietnamese ? "CHỌN GAME MỤC TIÊU" : "SELECT TARGET GAME", systemImage: "gamecontroller.fill")
                                    .font(.caption.weight(.black))
                                    .tracking(0.8)
                                    .foregroundStyle(DeltaColors.purple)
                                Spacer()
                                Text("FF")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(DeltaColors.purple)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(DeltaColors.purple.opacity(0.10), in: Capsule())
                            }

                            DeltaGameRow(game: .freeFire, selected: selectedGame == .freeFire) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedGame = .freeFire }
                            }
                            DeltaGameRow(game: .freeFireMax, selected: selectedGame == .freeFireMax) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedGame = .freeFireMax }
                            }
                        }

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { pressed = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { pressed = false }
                                onEnter()
                            }
                        } label: {
                            Label(isVietnamese ? "VÀO MENU" : "ENTER MENU", systemImage: "square.grid.2x2.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(
                                    LinearGradient(colors: [DeltaColors.purpleDark, DeltaColors.purple], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                                .shadow(color: DeltaColors.purple.opacity(0.32), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(pressed ? 0.96 : 1)

                        HStack(spacing: 10) {
                            languageButton("ENG", value: AppLanguage.english.rawValue)
                            languageButton("VN", value: AppLanguage.vietnamese.rawValue)
                        }

                        Label("Discord: discord.gg/YZ4A4EUW", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(DeltaColors.purple)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 26)
                }
            }
        }
    }

    private func languageButton(_ title: String, value: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { languageCode = value } } label: {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(languageCode == value ? DeltaColors.purple : DeltaColors.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(languageCode == value ? DeltaColors.purple.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DeltaGameRow: View {
    let game: DeltaGame
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(game == .freeFire ? "FreeFireNormal" : "FreeFireMax")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(game == .freeFire ? "Free Fire" : "Free Fire MAX")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DeltaColors.ink)
                Spacer()
                ZStack {
                    Circle().stroke(selected ? DeltaColors.purple : Color.gray.opacity(0.24), lineWidth: 2).frame(width: 18, height: 18)
                    if selected { Circle().fill(DeltaColors.purple).frame(width: 10, height: 10) }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(selected ? DeltaColors.purple.opacity(0.09) : Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? DeltaColors.purple : Color.clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

private struct DeltaAnnouncementView: View {
    let isVietnamese: Bool
    let dismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.40).ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [DeltaColors.purpleDark, DeltaColors.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("EXTERNAL")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                        Text("SYSTEM")
                            .font(.system(size: 31, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(20)
                }
                .frame(height: 150)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(isVietnamese ? "Thông Báo" : "Announcement", systemImage: "megaphone.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(DeltaColors.ink)
                        Spacer()
                        Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    Text(isVietnamese ? "Hiện Tại Chỉ Sử Dụng Được Aimbot Và AimBot Vector\n\nEXTERNAL SYSTEM cảm ơn các bạn đã đợi phiên bản mới.\n\nCó lỗi gì cứ góp ý nhé, chân thành cảm ơn các bạn" : "Hello everyone, this is a beta test version.\n\nCurrently, only AimBot and AimBot Vector are available for use.\n\nEXTERNAL SYSTEM thanks you all for waiting for the new version.\n\nIf you encounter any bugs or issues, feel free to give feedback. Thank you very much!")
                        .font(.subheadline)
                        .foregroundStyle(DeltaColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Button(action: dismiss) {
                        Text(isVietnamese ? "ĐÃ HIỂU" : "GOT IT")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(LinearGradient(colors: [DeltaColors.purpleDark, DeltaColors.purple], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
            .padding(.horizontal, 22)
            .scaleEffect(appeared ? 1 : 0.94)
        }
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { appeared = true } }
    }
}

private struct DeltaDashboardView: View {
    @Binding var selectedGame: DeltaGame
    @Binding var selectedTab: DeltaTab
    @Binding var languageCode: String
    @Binding var showErrorBanner: Bool
    let isVietnamese: Bool
    let appState: AppState
    let keySession: IOSKeySession

    var body: some View {
        ZStack(alignment: .top) {
            DeltaColors.page.ignoresSafeArea()
            VStack(spacing: 0) {
                DeltaHeader(selectedGame: $selectedGame, showEye: true, showBack: selectedTab != .dashboard) {
                    withAnimation(.easeInOut(duration: 0.22)) { selectedTab = .dashboard }
                }
                    .padding(.horizontal, 16)
                    .padding(.top, 7)

                ScrollView(showsIndicators: false) {
                    Group {
                        switch selectedTab {
                        case .dashboard: DeltaTabBar(selectedTab: $selectedTab, selectedGame: selectedGame, isVietnamese: isVietnamese)
                        case .cache: DeltaRemoteFeatureTab(feature: .cache, selectedGame: selectedGame)
                        case .avatar: DeltaRemoteFeatureTab(feature: .avatar, selectedGame: selectedGame)
                        case .hologram: DeltaRemoteFeatureTab(feature: .hologram, selectedGame: selectedGame)
                        case .external: DeltaExternalPanelTab(selectedGame: selectedGame)
                        case .skin: DeltaRemoteFeatureTab(feature: .skin, selectedGame: selectedGame)
                        case .settings: DeltaReferenceSettingsTab(languageCode: $languageCode, isVietnamese: isVietnamese, appState: appState, keySession: keySession)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .id(selectedTab)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            if showErrorBanner {
                DeltaErrorBanner {
                    withAnimation(.easeOut(duration: 0.2)) { showErrorBanner = false }
                }
                .padding(.top, 58)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedTab)
        .animation(.easeInOut(duration: 0.22), value: showErrorBanner)
    }
}

private struct DeltaHeader: View {
    @Binding var selectedGame: DeltaGame
    let showEye: Bool
    let showBack: Bool
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DeltaColors.purple)
                        .frame(width: 30, height: 30)
                        .background(DeltaColors.purple.opacity(0.11), in: Circle())
                }
                .buttonStyle(.plain)
            }
            AppLogo(size: 29)
            Text("EXTERNAL SYSTEM")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(DeltaColors.ink)
            Spacer()
            HStack(spacing: 0) {
                Button("FF") { withAnimation(.easeInOut(duration: 0.18)) { selectedGame = .freeFire } }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selectedGame == .freeFire ? .white : DeltaColors.muted)
                    .frame(width: 31, height: 25)
                    .background(selectedGame == .freeFire ? DeltaColors.purple : .clear, in: Capsule())
                Button("MAX") { withAnimation(.easeInOut(duration: 0.18)) { selectedGame = .freeFireMax } }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selectedGame == .freeFireMax ? .white : DeltaColors.muted)
                    .frame(width: 38, height: 25)
                    .background(selectedGame == .freeFireMax ? DeltaColors.purple : .clear, in: Capsule())
            }
            .padding(2)
            .background(Color.white, in: Capsule())
            .shadow(color: DeltaColors.purple.opacity(0.10), radius: 8, y: 3)
            if showEye {
                Image(systemName: "eye.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DeltaColors.purple)
                    .frame(width: 29, height: 29)
                    .background(DeltaColors.purple.opacity(0.10), in: Circle())
            }
        }
        .frame(height: 38)
    }
}

private struct DeltaTabBar: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    @Binding var selectedTab: DeltaTab
    let selectedGame: DeltaGame
    let isVietnamese: Bool

    private let patchTabs: [DeltaTab] = [.cache, .avatar, .hologram, .external, .skin]

    private var selectedCategory: PatchGameCategory {
        selectedGame == .freeFire ? .normal : .max
    }

    private func patchCount(for tab: DeltaTab) -> Int {
        guard let feature = PatchFeatureCategory(rawValue: tab.rawValue) else { return 0 }
        return patchStore.items.filter {
            PatchProjectLibrary.category(for: $0) == selectedCategory &&
            PatchProjectLibrary.featureCategory(for: $0) == feature
        }.count
    }

    private func select(_ tab: DeltaTab) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            selectedTab = tab
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ESCOLHA UMA CATEGORIA")
                    .font(.system(size: 11, weight: .black))
                    .tracking(1.1)
                    .foregroundStyle(DeltaColors.purple)
                Text(selectedGame == .freeFire ? "Patches disponíveis para FF" : "Patches disponíveis para FF MAX")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(DeltaColors.ink)
                Text("Toque em uma opção para abrir os patches.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeltaColors.muted)
            }

            HStack(spacing: 8) {
                DeltaCompactTabButton(tab: .dashboard, selectedTab: selectedTab, title: isVietnamese ? DeltaTab.dashboard.vietnameseTitle : DeltaTab.dashboard.title) {
                    select(.dashboard)
                }
                DeltaCompactTabButton(tab: .settings, selectedTab: selectedTab, title: isVietnamese ? DeltaTab.settings.vietnameseTitle : DeltaTab.settings.title) {
                    select(.settings)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(patchTabs.prefix(4), id: \.self) { tab in
                    DeltaCategoryCard(
                        tab: tab,
                        title: isVietnamese ? tab.vietnameseTitle : tab.title,
                        count: patchCount(for: tab),
                        isSelected: selectedTab == tab,
                        action: { select(tab) }
                    )
                }
                if let skin = patchTabs.last {
                    DeltaCategoryCard(
                        tab: skin,
                        title: isVietnamese ? skin.vietnameseTitle : skin.title,
                        count: patchCount(for: skin),
                        isSelected: selectedTab == skin,
                        action: { select(skin) }
                    )
                    .gridCellColumns(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

private struct DeltaCompactTabButton: View {
    let tab: DeltaTab
    let selectedTab: DeltaTab
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(selectedTab == tab ? DeltaColors.purple : DeltaColors.muted)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selectedTab == tab ? DeltaColors.purple.opacity(0.12) : Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DeltaCategoryCard: View {
    let tab: DeltaTab
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: tab == .skin ? 22 : 18, weight: .bold))
                    .foregroundStyle(isSelected ? .white : DeltaColors.purple)
                    .frame(width: 38, height: 38)
                    .background(isSelected ? Color.white.opacity(0.20) : DeltaColors.purple.opacity(0.11), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Text("\(count) patches")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(isSelected ? 0.82 : 0.62)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(isSelected ? 1 : 0.42)
            }
            .foregroundStyle(isSelected ? .white : DeltaColors.ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 61)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient(colors: [DeltaColors.purpleDark, DeltaColors.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white.opacity(0.80)),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.18) : DeltaColors.purple.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: isSelected ? DeltaColors.purple.opacity(0.18) : .black.opacity(0.04), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct DeltaHomeTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let selectedGame: DeltaGame

    private var selectedCategory: PatchGameCategory {
        selectedGame == .freeFire ? .normal : .max
    }

    private var remoteItems: [PatchLibraryItem] {
        patchStore.items.filter {
            PatchProjectLibrary.category(for: $0) == selectedCategory
        }
    }

    private func featureCount(_ feature: PatchFeatureCategory) -> Int {
        remoteItems.filter { PatchProjectLibrary.featureCategory(for: $0) == feature }.count
    }

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                Label("Welcome back to EXTERNAL SYSTEM! Have a good day.", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DeltaColors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DeltaCard {
                DeltaSectionTitle("INJECTED TARGET GAME", icon: "gamecontroller.fill")
                HStack(spacing: 10) {
                    Image(selectedGame == .freeFire ? "FreeFireNormal" : "FreeFireMax")
                        .resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedGame == .freeFire ? "Free Fire" : "Free Fire MAX").font(.subheadline.weight(.bold)).foregroundStyle(DeltaColors.ink)
                        Text("com.dts.freefireth").font(.caption2.monospaced()).foregroundStyle(DeltaColors.muted)
                    }
                    Spacer()
                    DeltaStatusBadge(text: "ACTIVE")
                }
            }
            DeltaCard {
                HStack {
                    DeltaSectionTitle("REMOTE PATCHES", icon: "arrow.down.circle.fill")
                    Spacer()
                    Button {
                        patchStore.syncNow()
                    } label: {
                        Image(systemName: patchStore.remoteSyncState == .syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DeltaColors.purple)
                            .rotationEffect(.degrees(patchStore.remoteSyncState == .syncing ? 180 : 0))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(patchStore.remoteSyncState == .online ? Color.green : patchStore.remoteSyncState == .syncing ? Color.orange : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(remoteStatusTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DeltaColors.muted)
                    Spacer()
                    Text("\(remoteItems.count) patches")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DeltaColors.purple)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    remoteFeatureBadge("Cache", icon: "externaldrive.fill", count: featureCount(.cache))
                    remoteFeatureBadge("Avatar", icon: "person.crop.circle.fill", count: featureCount(.avatar))
                    remoteFeatureBadge("Hologram", icon: "wand.and.stars", count: featureCount(.hologram))
                    remoteFeatureBadge("Aimbot / ESP", icon: "scope", count: featureCount(.external))
                    remoteFeatureBadge("Skin", icon: "tshirt.fill", count: featureCount(.skin), emphasized: true)
                }

            }
        }
    }

    private var remoteStatusTitle: String {
        switch patchStore.remoteSyncState {
        case .idle: return "Remote feed aguardando"
        case .syncing: return "Sincronizando feed remoto..."
        case .online: return "Feed remoto online"
        case .offline: return "Feed remoto offline"
        }
    }

    private func remoteFeatureBadge(_ title: String, icon: String, count: Int, emphasized: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: emphasized ? 22 : 16, weight: .semibold))
                .frame(width: emphasized ? 34 : 24, height: emphasized ? 28 : 22)
                .foregroundStyle(DeltaColors.purple)
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DeltaColors.ink)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(DeltaColors.purple)
        }
        .frame(maxWidth: .infinity, minHeight: emphasized ? 62 : 54)
        .background(Color(red: 0.97, green: 0.97, blue: 0.99), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DeltaExternalPanelTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let selectedGame: DeltaGame

    private var selectedCategory: PatchGameCategory {
        selectedGame == .freeFire ? .normal : .max
    }

    private var externalPatch: PatchLibraryItem? {
        patchStore.items.first { item in
            guard PatchProjectLibrary.category(for: item) == selectedCategory else { return false }
            let displayName = PatchProjectLibrary.displayName(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
            let projectName = (item.project?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = item.packageURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return displayName.caseInsensitiveCompare("External") == .orderedSame
                || projectName.caseInsensitiveCompare("External") == .orderedSame
                || fileName.caseInsensitiveCompare("External") == .orderedSame
        }
    }

    var body: some View {
        ExternalPanelView(
            store: patchStore,
            item: externalPatch,
            onRequestUnlock: { patchStore.requestUnlock(for: $0) }
        )
        .padding(.vertical, 8)
    }
}

private struct DeltaRemoteFeatureTab: View {
    @EnvironmentObject private var patchStore: PatchProjectStore
    let feature: PatchFeatureCategory
    let selectedGame: DeltaGame
    @State private var expandedItemID: UUID?

    private var items: [PatchLibraryItem] {
        let category: PatchGameCategory = selectedGame == .freeFire ? .normal : .max
        return patchStore.items.filter {
            guard PatchProjectLibrary.category(for: $0) == category else { return false }
            if feature == .external {
                let displayName = PatchProjectLibrary.displayName(for: $0)
                let fileName = $0.packageURL.deletingPathExtension().lastPathComponent
                return PatchProjectLibrary.featureCategory(for: $0) == .external
                    || displayName.localizedCaseInsensitiveContains("external")
                    || fileName.localizedCaseInsensitiveContains("external")
            }
            return PatchProjectLibrary.featureCategory(for: $0) == feature
        }
    }

    private var title: String {
        switch feature {
        case .cache: return "CACHE PATCHES"
        case .avatar: return "AVATAR PATCHES"
        case .hologram: return "HOLOGRAM PATCHES"
        case .external: return "EXTERNAL PATCHES"
        case .skin: return "SKIN PATCHES"
        }
    }

    private var icon: String {
        switch feature {
        case .cache: return "externaldrive.fill"
        case .avatar: return "person.crop.circle.fill"
        case .hologram: return "wand.and.stars"
        case .external: return "scope"
        case .skin: return "tshirt.fill"
        }
    }

    private func isApplied(_ item: PatchLibraryItem) -> Bool {
        DevicePatchService.latestReceipt(projectID: item.id) != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                HStack {
                    if feature == .skin {
                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(DeltaColors.purple)
                            .frame(width: 42, height: 42)
                            .background(DeltaColors.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(title)
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(DeltaColors.ink)
                    } else {
                        DeltaSectionTitle(title, icon: icon)
                    }
                    Spacer()
                    Text("\(items.count) REMOTE")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(DeltaColors.purple)
                }
                Text("Toque no patch para expandir. Depois você pode aplicar ou restaurar o original.")
                    .font(.caption)
                    .foregroundStyle(DeltaColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if items.isEmpty {
                DeltaCard {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(DeltaColors.purple)
                        Text(patchStore.remoteSyncState == .syncing ? "Sincronizando patches remotos..." : "Nenhum patch nesta categoria ainda")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DeltaColors.ink)
                            .multilineTextAlignment(.center)
                        Text("Atualize o feed no Dashboard e permaneça nesta aba para acompanhar os patches recebidos.")
                            .font(.caption)
                            .foregroundStyle(DeltaColors.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            } else {
                ForEach(items) { item in
                    let applied = isApplied(item)
                    DeltaCard {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                expandedItemID = expandedItemID == item.id ? nil : item.id
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if feature == .skin, let iconURL = PatchProjectLibrary.remoteIconURL(for: item.id) {
                                    AsyncImage(url: iconURL) { phase in
                                        if let image = phase.image { image.resizable().scaledToFit().padding(7) }
                                        else { Image(systemName: icon).resizable().scaledToFit().padding(15).foregroundStyle(DeltaColors.purple) }
                                    }
                                    .frame(width: 78, height: 78)
                                    .background(DeltaColors.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                } else {
                                    Image(systemName: icon)
                                        .font(.title3)
                                        .foregroundStyle(DeltaColors.purple)
                                        .frame(width: 42, height: 42)
                                        .background(DeltaColors.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(PatchProjectLibrary.displayName(for: item).isEmpty ? (item.project?.name ?? item.packageURL.deletingPathExtension().lastPathComponent) : PatchProjectLibrary.displayName(for: item))
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(DeltaColors.ink)
                                        .lineLimit(1)
                                    Text(applied ? (feature == .external ? "Running — tap to clear data" : "Applied — tap to restore") : item.isLocked ? "Protected — tap to unlock" : "Tap to configure")
                                        .font(.caption2)
                                        .foregroundStyle(DeltaColors.muted)
                                }
                                Spacer()
                                Image(systemName: expandedItemID == item.id ? "chevron.up.circle.fill" : "chevron.down.circle")
                                    .foregroundStyle(DeltaColors.purple)
                            }
                        }
                        .buttonStyle(.plain)

                        if expandedItemID == item.id {
                            Divider().overlay(DeltaColors.purple.opacity(0.12))
                            if applied {
                                Button {
                                    patchStore.restoreInline(item)
                                } label: {
                                    Label(feature == .external ? "CLEAR DATA" : "RESTORE ORIGINAL", systemImage: "arrow.uturn.backward.circle.fill")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(patchStore.isBusy)
                            } else if item.isLocked {
                                Button {
                                    patchStore.requestUnlock(for: item)
                                } label: {
                                    Label("UNLOCK PATCH", systemImage: "lock.open.fill")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(DeltaColors.purple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(patchStore.isBusy)
                            } else {
                                Button {
                                    patchStore.applyInline(item)
                                } label: {
                                    Label(feature == .external ? "START" : "APPLY PATCH", systemImage: "play.fill")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(DeltaColors.purple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(patchStore.isBusy)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DeltaAimbotTab: View {
    @State private var launchAntiBan = false
    @State private var aimbot = true
    @State private var vector = false
    @State private var silent = false
    @State private var bone = 0
    @State private var drawFOV = false
    @State private var fov = 120.0
    @State private var distance = 150.0
    @State private var ignoreKnocked = false

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                DeltaSectionTitle("ANTI-BAN", icon: "shield.fill")
                DeltaToggleRow("Launch Anti-Ban", isOn: $launchAntiBan)
            }
            DeltaCard {
                DeltaSectionTitle("AIMBOT TYPE", icon: "scope")
                DeltaToggleRow("Aimbot", isOn: $aimbot)
                DeltaToggleRow("Aimbot Vector", isOn: $vector)
                DeltaToggleRow("Aim Silent", isOn: $silent)
                DeltaSegmented(title: "Bone:", items: ["Head", "Neck", "Body"], selection: $bone)
            }
            DeltaCard {
                DeltaSectionTitle("AIMBOT SETTINGS", icon: "slider.horizontal.3")
                DeltaToggleRow("Draw Field Of View", isOn: $drawFOV)
                DeltaSliderRow("Field Of View", value: $fov, range: 0...120, suffix: "°")
                DeltaSliderRow("Aimbot Distance", value: $distance, range: 0...150, suffix: "m")
                DeltaToggleRow("Ignore Knocked", isOn: $ignoreKnocked)
            }
        }
    }
}

private struct DeltaVisualTab: View {
    @Binding var showErrorBanner: Bool
    @State private var master = false
    @State private var line = false
    @State private var box = false
    @State private var name = false
    @State private var distance = false
    @State private var health = false
    @State private var skeleton = false
    @State private var count = false
    @State private var boxType = 0
    @State private var healthType = 0
    @State private var textSize = 1.0
    @State private var thickness = 1.0
    @State private var visualDistance = 150.0

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                DeltaSectionTitle("ESP MAIN", icon: "eye.fill")
                DeltaToggleRow("ESP Master", isOn: $master)
                DeltaToggleRow("ESP Line", isOn: $line, enabled: master) { if !master { showErrorBanner = true } }
                DeltaToggleRow("ESP Box", isOn: $box, enabled: master) { if !master { showErrorBanner = true } }
                DeltaSegmented(title: "Box Type:", items: ["Cornered", "2D Bounding"], selection: $boxType)
                DeltaToggleRow("ESP Name", isOn: $name, enabled: master) { if !master { showErrorBanner = true } }
                DeltaToggleRow("ESP Distance", isOn: $distance, enabled: master) { if !master { showErrorBanner = true } }
                DeltaToggleRow("ESP Health", isOn: $health, enabled: master) { if !master { showErrorBanner = true } }
                DeltaSegmented(title: "Health Type:", items: ["Right", "Left"], selection: $healthType)
                DeltaToggleRow("ESP Skeleton", isOn: $skeleton, enabled: master) { if !master { showErrorBanner = true } }
                DeltaToggleRow("Draw Count Enemies", isOn: $count, enabled: master) { if !master { showErrorBanner = true } }
            }
            DeltaCard {
                DeltaSectionTitle("VISUAL SLIDERS", icon: "slider.horizontal.3")
                DeltaSliderRow("Text Size", value: $textSize, range: 0.5...2.0, suffix: "")
                DeltaSliderRow("Thickness Size", value: $thickness, range: 0.5...2.0, suffix: "")
                DeltaSliderRow("Visual Distance", value: $visualDistance, range: 0...150, suffix: "m")
            }
        }
    }
}

private struct DeltaMiscTab: View {
    @State private var noRecoil = false
    @State private var noReload = false
    @State private var speedHacks = false
    @State private var speed = 1.0
    @State private var fastMedkit = false
    @State private var rapidFire = false
    @State private var rapid = 1.0

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                DeltaSectionTitle("MISC FEATURES", icon: "bolt.fill")
                DeltaToggleRow("No Recoil", isOn: $noRecoil)
                DeltaToggleRow("No Reload", isOn: $noReload)
                DeltaToggleRow("Speed Hacks", isOn: $speedHacks)
                DeltaSliderRow("Speed", value: $speed, range: 0.5...2.0, suffix: "x")
                DeltaToggleRow("Fast Medkit", isOn: $fastMedkit)
                DeltaToggleRow("Rapid Fire", isOn: $rapidFire)
                DeltaSliderRow("Rapid", value: $rapid, range: 0.5...2.0, suffix: "x")
            }
        }
    }
}

private struct DeltaReferenceSettingsTab: View {
    @Binding var languageCode: String
    let isVietnamese: Bool
    let appState: AppState
    let keySession: IOSKeySession
    @AppStorage("externalSystem.streamProofEnabled") private var streamProof = false
    @AppStorage(DeltaColors.themeKey) private var themeRaw = DeltaTheme.lavender.rawValue
    @State private var copied = false
    private var deviceUID: String {
        UIDevice.current.identifierForVendor?.uuidString.uppercased() ?? "UNAVAILABLE"
    }

    var body: some View {
        VStack(spacing: 12) {
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "PALETA DO APLICATIVO" : "APP COLOR PALETTE", icon: "paintpalette.fill")
                Text(isVietnamese ? "Escolha uma cor para aplicar em todo o EXTERNAL SYSTEM." : "Choose a color to apply across the entire EXTERNAL SYSTEM app.")
                    .font(.caption)
                    .foregroundStyle(DeltaColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(DeltaTheme.allCases) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { themeRaw = theme.rawValue }
                        } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(theme.swatch)
                                    .frame(width: 27, height: 27)
                                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1))
                                Text(theme.title)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(DeltaColors.ink)
                                Spacer(minLength: 0)
                                if themeRaw == theme.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DeltaColors.purple)
                                }
                            }
                            .padding(.horizontal, 9)
                            .frame(minHeight: 45)
                            .background(themeRaw == theme.rawValue ? DeltaColors.purple.opacity(0.12) : Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(themeRaw == theme.rawValue ? DeltaColors.purple.opacity(0.48) : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "QUYỀN RIÊNG TƯ" : "PRIVACY", icon: "video.slash.fill")
                DeltaToggleRow(isVietnamese ? "Chống stream" : "Stream Proof", isOn: $streamProof)
            }
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "THÔNG TIN BẢN QUYỀN" : "LICENSE INFORMATION", icon: "key.fill")
                DeltaInfoRow(isVietnamese ? "Bản quyền:" : "License:", value: "EXTERNAL SYSTEM")
                DeltaInfoRow(isVietnamese ? "Hạn dùng:" : "Expired:", value: "Lifetime")
                HStack {
                    Text("UID:").font(.caption).foregroundStyle(DeltaColors.muted)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = deviceUID
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    } label: {
                        Text(copied ? "✓" : (isVietnamese ? "Sao chép" : "Copy"))
                            .font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5).background(DeltaColors.purple, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Text(deviceUID).font(.system(size: 8, design: .monospaced)).foregroundStyle(DeltaColors.ink).lineLimit(1).minimumScaleFactor(0.6)
            }
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "TƯƠNG THÍCH HỆ ĐIỀU HÀNH" : "SYSTEM COMPATIBILITY", icon: "apple.logo")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isVietnamese ? "Phiên bản iOS hiện tại:" : "Current iOS Version:").font(.caption).foregroundStyle(DeltaColors.ink)
                        Text("iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))").font(.caption2).foregroundStyle(DeltaColors.muted)
                    }
                    Spacer()
                    DeltaStatusBadge(text: appState.isSupported ? (isVietnamese ? "HỖ TRỢ" : "SUPPORTED") : "UNSUPPORTED")
                }
            }
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "NGÔN NGỮ" : "LANGUAGE", icon: "globe")
                HStack(spacing: 0) {
                    DeltaLanguageButton(title: "English", active: languageCode == AppLanguage.english.rawValue) { languageCode = AppLanguage.english.rawValue }
                    DeltaLanguageButton(title: "Tiếng Việt", active: languageCode == AppLanguage.vietnamese.rawValue) { languageCode = AppLanguage.vietnamese.rawValue }
                }
                .padding(3).background(Color.gray.opacity(0.18), in: Capsule())
            }
            DeltaCard {
                DeltaSectionTitle(isVietnamese ? "HỖ TRỢ HỆ THỐNG" : "SUPPORT & SYSTEM", icon: "questionmark.circle.fill")
                Button { } label: { DeltaActionRow(icon: "bubble.left.and.bubble.right.fill", title: isVietnamese ? "Liên hệ hỗ trợ (Discord)" : "Discord Support", color: DeltaColors.purple) }.buttonStyle(.plain)
                Divider().overlay(DeltaColors.purple.opacity(0.10))
                Button { keySession.logout() } label: { DeltaActionRow(icon: "rectangle.portrait.and.arrow.right", title: isVietnamese ? "Đăng xuất tài khoản" : "Sign Out", color: .red) }.buttonStyle(.plain)
            }
        }
    }
}

private struct DeltaCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(12)
            .background(DeltaColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
            .shadow(color: DeltaColors.purple.opacity(0.06), radius: 8, y: 4)
    }
}

private struct DeltaSectionTitle: View {
    let title: String
    let icon: String
    init(_ title: String, icon: String) { self.title = title; self.icon = icon }
    var body: some View { Label(title, systemImage: icon).font(.system(size: 9, weight: .black)).tracking(0.7).foregroundStyle(DeltaColors.purple) }
}

private struct DeltaStatusBadge: View {
    let text: String
    var body: some View { HStack(spacing: 4) { Circle().fill(Color.green).frame(width: 5, height: 5); Text(text).font(.system(size: 8, weight: .bold)) }.foregroundStyle(Color(red: 0.05, green: 0.60, blue: 0.40)).padding(.horizontal, 7).padding(.vertical, 4).background(Color.green.opacity(0.12), in: Capsule()) }
}

private struct DeltaMetric: View {
    let title: String
    let subtitle: String
    let icon: String
    init(_ title: String, subtitle: String, icon: String) { self.title = title; self.subtitle = subtitle; self.icon = icon }
    var body: some View { VStack(alignment: .leading, spacing: 3) { Image(systemName: icon).font(.caption2).foregroundStyle(DeltaColors.purple); Text(title).font(.caption2.weight(.bold)).foregroundStyle(DeltaColors.ink); Text(subtitle).font(.system(size: 8)).foregroundStyle(DeltaColors.muted) }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color(red: 0.97, green: 0.97, blue: 0.99), in: RoundedRectangle(cornerRadius: 7)) }
}

private struct DeltaToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { RoundedRectangle(cornerRadius: 12).fill(configuration.isOn ? DeltaColors.purple : Color.gray.opacity(0.45)).frame(width: 37, height: 23).overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(.white).frame(width: 18, height: 18).padding(2) }.animation(.spring(response: 0.24, dampingFraction: 0.8), value: configuration.isOn).onTapGesture { configuration.isOn.toggle() }
    }
}

private struct DeltaToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true
    var onDisabledTap: (() -> Void)? = nil
    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true, onDisabledTap: (() -> Void)? = nil) { self.title = title; self._isOn = isOn; self.enabled = enabled; self.onDisabledTap = onDisabledTap }
    var body: some View { HStack { Text(title).font(.caption).foregroundStyle(enabled ? DeltaColors.ink : DeltaColors.muted); Spacer(); Toggle("", isOn: $isOn).labelsHidden().toggleStyle(DeltaToggleStyle()).opacity(enabled ? 1 : 0.70) }.contentShape(Rectangle()).onTapGesture { if !enabled { onDisabledTap?() } } }
}

private struct DeltaSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) {
        self.title = title
        self._value = value
        self.range = range
        self.suffix = suffix
    }
    var body: some View { VStack(spacing: 2) { HStack { Text(title).font(.caption).foregroundStyle(DeltaColors.ink); Spacer(); Text(String(format: suffix == "m" ? "%.0f%@" : suffix == "°" ? "%.0f%@" : "%.1f%@", value, suffix)).font(.caption2.weight(.bold)).foregroundStyle(DeltaColors.purple) }; Slider(value: $value, in: range).tint(DeltaColors.purple) } }
}

private struct DeltaSegmented: View {
    let title: String
    let items: [String]
    @Binding var selection: Int
    var body: some View { HStack(spacing: 8) { Text(title).font(.caption2).foregroundStyle(DeltaColors.muted); HStack(spacing: 0) { ForEach(items.indices, id: \.self) { index in Button(items[index]) { withAnimation(.easeInOut(duration: 0.18)) { selection = index } }.font(.system(size: 9, weight: .medium)).foregroundStyle(selection == index ? DeltaColors.ink : DeltaColors.muted).frame(maxWidth: .infinity, minHeight: 24).background(selection == index ? Color.white : .clear, in: Capsule()) } }.padding(2).background(Color.gray.opacity(0.18), in: Capsule()) } }
}

private struct DeltaInfoRow: View {
    let label: String
    let value: String
    init(_ label: String, value: String) { self.label = label; self.value = value }
    var body: some View { HStack { Text(label).font(.caption).foregroundStyle(DeltaColors.muted); Spacer(); Text(value).font(.caption.weight(.bold)).foregroundStyle(DeltaColors.ink) } }
}

private struct DeltaLanguageButton: View {
    let title: String
    let active: Bool
    let action: () -> Void
    var body: some View { Button(action: action) { Text(title).font(.caption2.weight(active ? .bold : .medium)).foregroundStyle(active ? DeltaColors.ink : DeltaColors.muted).frame(maxWidth: .infinity, minHeight: 25).background(active ? Color.white : .clear, in: Capsule()) }.buttonStyle(.plain) }
}

private struct DeltaActionRow: View {
    let icon: String
    let title: String
    let color: Color
    var body: some View { HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(color).frame(width: 20); Text(title).font(.caption.weight(.semibold)).foregroundStyle(color); Spacer(); Image(systemName: "arrow.up.right").font(.caption2.bold()).foregroundStyle(color) }.padding(.vertical, 7) }
}

private struct DeltaErrorBanner: View {
    let dismiss: () -> Void
    var body: some View { HStack { Text("ESP OFF (bật ESP Master)").font(.caption.weight(.bold)).foregroundStyle(.white); Spacer(); Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.8)) } }.padding(.horizontal, 14).padding(.vertical, 11).background(Color(red: 0.04, green: 0.04, blue: 0.06)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).shadow(color: .black.opacity(0.18), radius: 10, y: 5).padding(.horizontal, 8) }
}
