import Foundation
import SwiftUI
import AVKit

struct MotionBGSWallpaper: Identifiable, Hashable {
    let id: String
    let title: String
    let slug: String
    let mediaID: Int

    var thumbnailURL: URL? {
        URL(string: "https://motionbgs.com/i/c/364x205/media/\(mediaID)/\(slug).3840x2160.jpg")
    }

    var videoURL: URL? {
        URL(string: "https://motionbgs.com/dl/hd/\(mediaID)")
    }
}

enum MotionBGSWallpaperCatalog {
    static let all: [MotionBGSWallpaper] = [
        ("galaxy-eyes", "Galaxy Eyes", "galaxy-eyes", 10050),
        ("faust-limbus-company", "Faust Limbus Company", "faust-limbus-company", 10179),
        ("uncle-panda-remnant-tale", "Uncle Panda Remnant Tale", "uncle-panda-remnant-tale", 10228),
        ("black-silk-waves", "Black Silk Waves", "black-silk-waves", 10046),
        ("lich-king", "Lich King Winter's Wrath", "lich-king", 10208),
        ("crimson-flower-empress", "Crimson Flower Empress", "crimson-flower-empress", 10229),
        ("dark-angel-rising", "Dark Angel Rising", "dark-angel-rising", 10102),
        ("illustrious-wandering-glow-of-midnight", "Illustrious - Wandering Glow of Midnight", "illustrious-wandering-glow-of-midnight", 10197),
        ("cozy-autumn-nap", "Cozy Autumn Nap", "cozy-autumn-nap", 10214),
        ("yuta-and-cursed-rika", "Yuta and Cursed Rika", "yuta-and-cursed-rika", 10060),
        ("ada-wong-black-ops", "Ada Wong Black Ops", "ada-wong-black-ops", 10204),
        ("jinhsi", "Jinhsi Butterfly Blossom", "jinhsi", 10196),
        ("sukuna-fuga-flames", "Sukuna Fuga Flames", "sukuna-fuga-flames", 10057),
        ("mr-robot-hidden-identity", "Mr. Robot Hidden Identity", "mr-robot-hidden-identity", 10175),
        ("psyops-vi-lol", "PsyOps Vi (LoL)", "psyops-vi-lol", 9224),
        ("eyes-toward-heaven", "Eyes Toward Heaven", "eyes-toward-heaven", 10052),
        ("hsin-wuthering-waves", "Hsin (Wuthering Waves)", "hsin-wuthering-waves", 10164),
        ("illidan-fel-fury", "Illidan Fel Fury (WoW)", "illidan-fel-fury", 10200),
        ("knight-of-the-abyss", "Knight of the Abyss", "knight-of-the-abyss", 10121),
        ("autumn-cats-at-sunset", "Autumn Cats at Sunset", "autumn-cats-at-sunset", 10226),
        ("chen-zixi", "Chen Zixi (Where Winds Meet)", "chen-zixi", 10219),
        ("sabrina-carpenter-kissing-screen", "Sabrina Carpenter Kissing Screen", "sabrina-carpenter-kissing-screen", 10065),
        ("ronova-genshin-impact", "Ronova - Genshin Impact", "ronova-genshin-impact", 10220),
        ("hachiware-elisa", "Hachiware Elisa", "hachiware-elisa", 10222)
    ].map { MotionBGSWallpaper(id: $0.0, title: $0.1, slug: $0.2, mediaID: $0.3) }

    static var selected: MotionBGSWallpaper? {
        guard let id = UserDefaults.standard.string(forKey: AppTheme.wallpaperSelectionStorageKey),
              id != "none" else { return nil }
        return all.first(where: { $0.id == id })
    }
}

private final class MotionBGSLoopingPlayer: ObservableObject {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL?) {
        player = AVQueuePlayer()
        super.init()
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
    }
}

struct MotionBGSVideoBackground: View {
    let wallpaper: MotionBGSWallpaper
    @StateObject private var model: MotionBGSLoopingPlayer

    init(wallpaper: MotionBGSWallpaper) {
        self.wallpaper = wallpaper
        _model = StateObject(wrappedValue: MotionBGSLoopingPlayer(url: wallpaper.videoURL))
    }

    var body: some View {
        VideoPlayer(player: model.player)
            .aspectRatio(contentMode: .fill)
            .clipped()
            .allowsHitTesting(false)
            .onAppear { model.player.play() }
            .onDisappear { model.player.pause() }
            .accessibilityHidden(true)
    }
}

enum AppAccentPalette: String, CaseIterable, Identifiable {
    case orange
    case blue
    case purple
    case green
    case pink
    case red
    case teal
    case cyan
    case yellow
    case indigo
    case lavender
    case gold
    case lime
    case crimson
    case sky
    case magenta
    case slate

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: return Color(red: 0.92, green: 0.40, blue: 0.16)
        case .blue: return Color(red: 0.16, green: 0.45, blue: 0.95)
        case .purple: return Color(red: 0.55, green: 0.30, blue: 0.90)
        case .green: return Color(red: 0.12, green: 0.62, blue: 0.36)
        case .pink: return Color(red: 0.92, green: 0.25, blue: 0.52)
        case .red: return Color(red: 0.88, green: 0.18, blue: 0.20)
        case .teal: return Color(red: 0.08, green: 0.62, blue: 0.66)
        case .cyan: return Color(red: 0.05, green: 0.78, blue: 0.88)
        case .yellow: return Color(red: 0.98, green: 0.78, blue: 0.12)
        case .indigo: return Color(red: 0.30, green: 0.32, blue: 0.92)
        case .lavender: return Color(red: 0.70, green: 0.52, blue: 0.96)
        case .gold: return Color(red: 0.92, green: 0.60, blue: 0.14)
        case .lime: return Color(red: 0.56, green: 0.78, blue: 0.12)
        case .crimson: return Color(red: 0.72, green: 0.08, blue: 0.24)
        case .sky: return Color(red: 0.22, green: 0.62, blue: 0.96)
        case .magenta: return Color(red: 0.78, green: 0.16, blue: 0.72)
        case .slate: return Color(red: 0.36, green: 0.43, blue: 0.55)
        }
    }
}

enum AppTheme {
    static let accentPaletteStorageKey = "theme.accent.palette"
    static let wallpaperSelectionStorageKey = "theme.motionbgs.wallpaper"
    static let glassOpacityStorageKey = "theme.glass.opacity"
    static let wallpaperBlurStorageKey = "theme.wallpaper.blur"
    static let animationSpeedStorageKey = "theme.animation.speed"
    static let saturationStorageKey = "theme.saturation"
    static let defaultAccentPalette = AppAccentPalette.orange.rawValue
    static let defaultGlassOpacity = 0.14
    static let defaultWallpaperBlur = 26.0
    static let defaultAnimationSpeed = 1.0
    static let defaultSaturation = 1.0

    static var accent: Color {
        AppAccentPalette(
            rawValue: UserDefaults.standard.string(forKey: accentPaletteStorageKey)
                ?? defaultAccentPalette
        )?.color ?? AppAccentPalette.orange.color
    }
    static var glassOpacity: Double { UserDefaults.standard.object(forKey: glassOpacityStorageKey) as? Double ?? defaultGlassOpacity }
    static var wallpaperBlur: CGFloat { CGFloat(UserDefaults.standard.object(forKey: wallpaperBlurStorageKey) as? Double ?? defaultWallpaperBlur) }
    static var animationSpeed: Double { UserDefaults.standard.object(forKey: animationSpeedStorageKey) as? Double ?? defaultAnimationSpeed }
    static var saturation: Double { UserDefaults.standard.object(forKey: saturationStorageKey) as? Double ?? defaultSaturation }
    static let pageBackground = Color.black
    static let consoleBackground = Color(red: 0.075, green: 0.075, blue: 0.09)
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
    static let contentCardCornerRadius: CGFloat = 14
    static let contentCardInset: CGFloat = 16
    static let contentCardPadding: CGFloat = 16
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: AppTheme.contentCardCornerRadius,
            style: .continuous
        )
        .strokeBorder(
            Color(uiColor: .separator).opacity(0.22),
            lineWidth: 0.5
        )
        .accessibilityHidden(true)
    }
}

struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.contentCardCornerRadius
    var tint: Color = .white
    var opacity: Double = 0.14

    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.105, green: 0.105, blue: 0.12).opacity(0.96), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(tint.opacity(opacity * 0.34), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 3)
                    .blur(radius: 2)
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(colors: [.white, .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
    }
}

extension View {
    func liquidGlassCard(
        cornerRadius: CGFloat = AppTheme.contentCardCornerRadius,
        tint: Color = .white,
        opacity: Double = 0.14
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, tint: tint, opacity: opacity))
    }
}

struct ExternalSystemLaunchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        ZStack {
            AnimatedGlassWallpaper()
            VStack(spacing: 18) {
                AppLogo(size: 92)
                    .scaleEffect(glow ? 1.04 : 0.94)
                    .shadow(color: AppTheme.accent.opacity(0.65), radius: glow ? 28 : 12)
                VStack(spacing: 5) {
                    Text("EXTERNAL SYSTEM")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .tracking(2.2)
                    Text("PATCH CONTROL")
                        .font(.caption.weight(.bold))
                        .tracking(2.8)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(36)
            .liquidGlassCard(cornerRadius: 34, tint: AppTheme.accent, opacity: 0.12)
            .padding(28)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("External System")
    }
}

struct ParallaxBrandHeader: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * AppTheme.animationSpeed
            HStack(spacing: 8) {
                AppLogo(size: 28)
                    .offset(x: sin(phase * 0.8) * 1.6, y: cos(phase * 0.7) * 0.8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EXTERNAL SYSTEM")
                        .font(.subheadline.weight(.black))
                        .tracking(0.8)
                        .offset(x: cos(phase * 0.55) * 0.8)
                    Text("PATCH CONTROL")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                        .offset(x: sin(phase * 0.45) * 0.5)
                }
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green.opacity(0.7), radius: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .liquidGlassCard(cornerRadius: 16, tint: AppTheme.accent, opacity: 0.08)
        }
        .frame(height: 42)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("External System")
    }
}

struct AnimatedGlassWallpaper: View {
    @AppStorage(AppTheme.wallpaperSelectionStorageKey) private var selectedWallpaperID = "none"

    var body: some View {
        if let wallpaper = MotionBGSWallpaperCatalog.all.first(where: { $0.id == selectedWallpaperID }),
           wallpaper.videoURL != nil {
            MotionBGSVideoBackground(wallpaper: wallpaper)
                .overlay(Color.black.opacity(0.26))
        } else {
            fallbackWallpaper
        }
    }

    private var fallbackWallpaper: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * AppTheme.animationSpeed
            let intensity = max(0.65, min(2.0, AppTheme.glassOpacity / AppTheme.defaultGlassOpacity))
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color(red: 0.055, green: 0.055, blue: 0.065),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                blob(
                    color: AppTheme.accent.opacity(min(0.28, 0.12 * intensity)),
                    size: 340,
                    x: sin(phase * 0.34) * 125,
                    y: cos(phase * 0.28) * 155
                )
                blob(
                    color: Color.white.opacity(min(0.12, 0.045 * intensity)),
                    size: 280,
                    x: cos(phase * 0.24) * 155,
                    y: sin(phase * 0.38) * 175
                )
                blob(
                    color: AppTheme.accent.opacity(min(0.18, 0.07 * intensity)),
                    size: 190,
                    x: sin(phase * 0.20 + 2) * 150,
                    y: cos(phase * 0.30 + 1) * 110
                )
            }
            .blur(radius: AppTheme.wallpaperBlur)
            .saturation(AppTheme.saturation)
        }
        .allowsHitTesting(false)
    }

    private func blob(color: Color, size: CGFloat, x: Double, y: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppIcon60x60")
                ?? Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
                ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}


struct ReferenceToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(configuration.isOn ? Color.white : Color.white.opacity(0.32))
                .frame(width: 54, height: 30)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.black : Color.white)
                        .frame(width: 26, height: 26)
                        .padding(3)
                }
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.22), lineWidth: 0.6))
                .animation(.easeOut(duration: 0.18), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
