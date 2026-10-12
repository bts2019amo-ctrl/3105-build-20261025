import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var patchStore: PatchProjectStore
    @EnvironmentObject private var keySession: IOSKeySession

    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(AppTheme.accentPaletteStorageKey)
    private var accentPalette = AppAccentPalette.purple.rawValue
    @AppStorage(AppTheme.glassOpacityStorageKey)
    private var glassOpacity = AppTheme.defaultGlassOpacity
    @AppStorage(AppTheme.wallpaperBlurStorageKey)
    private var wallpaperBlur = AppTheme.defaultWallpaperBlur
    @AppStorage(AppTheme.animationSpeedStorageKey)
    private var animationSpeed = AppTheme.defaultAnimationSpeed
    @AppStorage(AppTheme.saturationStorageKey)
    private var saturation = AppTheme.defaultSaturation
    @AppStorage("settings.stream.proof") private var streamProof = true

    @State private var appear = false
    @State private var showCopied = false
    @State private var showAdvanced = false
    @State private var isEyeModeEnabled = false

    private var selectedPalette: AppAccentPalette {
        AppAccentPalette(rawValue: accentPalette) ?? .purple
    }

    private var installationID: String {
        UIDevice.current.identifierForVendor?.uuidString.uppercased()
            ?? "IV-110A980E-961C-4AC1-9DA7-02D66DFCFE10"
    }

    private var motionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack {
            ReferenceBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    referenceHeader
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : -12)

                    privacyCard
                    licenseCard
                    compatibilityCard
                    languageCard
                    supportCard

                    if showAdvanced {
                        advancedAppearanceCard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            referenceToolbar
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(AppTheme.accent)
        .onAppear {
            withAnimation(motionAnimation) { appear = true }
        }
        .animation(motionAnimation, value: showAdvanced)
    }

    private var referenceHeader: some View {
        HStack(spacing: 12) {
            AppLogo(size: 48)
                .shadow(color: AppTheme.accent.opacity(0.26), radius: 10, y: 5)

            Text("3105")
                .font(.system(size: 27, weight: .black, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Color(red: 0.10, green: 0.08, blue: 0.29))

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Text("FF")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 36)
                    .background(AppTheme.accent, in: Capsule())
                    .shadow(color: AppTheme.accent.opacity(0.26), radius: 8, y: 3)

                Text("MAX")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, height: 36)
            }
            .padding(3)
            .background(Color.white.opacity(0.90), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 5)

            Button {
                withAnimation(motionAnimation) { isEyeModeEnabled.toggle() }
            } label: {
                Image(systemName: isEyeModeEnabled ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accent.opacity(0.10), in: Circle())
                    .scaleEffect(isEyeModeEnabled ? 0.92 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alternar modo de visualização")
        }
        .padding(.vertical, 6)
    }

    private var privacyCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "PRIVACY", systemImage: "video.slash.fill")
            HStack {
                Text("Stream Proof")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(ReferencePalette.ink)
                Spacer()
                Toggle("", isOn: $streamProof)
                    .labelsHidden()
                    .toggleStyle(ReferenceToggleStyle())
            }
            .padding(.top, 12)
        }
    }

    private var licenseCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "LICENSE INFORMATION", systemImage: "key.fill")

            VStack(spacing: 13) {
                referenceValue("License:", "3105")
                referenceValue("Expired:", "Lifetime")
                HStack(alignment: .center) {
                    Text("UUID:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = installationID
                        withAnimation(motionAnimation) { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation(motionAnimation) { showCopied = false }
                        }
                    } label: {
                        Text(showCopied ? "Copied" : "Copy")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 8)
                            .background(AppTheme.accent, in: Capsule())
                            .scaleEffect(showCopied ? 1.05 : 1)
                    }
                    .buttonStyle(.plain)
                }

                Text(installationID)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(ReferencePalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
            }
            .padding(.top, 14)
        }
    }

    private var compatibilityCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "SYSTEM COMPATIBILITY", systemImage: "apple.logo")
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current iOS Version:")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(ReferencePalette.ink)
                    Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SupportBadge(isSupported: appState.isSupported)
            }
            .padding(.top, 14)
        }
    }

    private var languageCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "LANGUAGE", systemImage: "globe")
            Picker("Language", selection: $languageCode) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 12)
        }
    }

    private var supportCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "SUPPORT & SYSTEM", systemImage: "questionmark.circle.fill")

            VStack(spacing: 0) {
                Button {
                    patchStore.syncNow()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 34)
                        Text("Discord Support")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(ReferencePalette.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 13)

                Divider().overlay(AppTheme.accent.opacity(0.12))

                Button {
                    keySession.logout()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 34)
                        Text("Sign Out")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 13)
            }
            .padding(.top, 8)
        }
    }

    private var advancedAppearanceCard: some View {
        ReferenceCard {
            ReferenceSectionHeader(title: "APPEARANCE", systemImage: "wand.and.stars")
            appearanceSlider("Glass transparency", value: $glassOpacity, range: 0.05...0.30, format: "%.0f%%")
            appearanceSlider("Background blur", value: $wallpaperBlur, range: 8...46, format: "%.0f")
            appearanceSlider("Animation speed", value: $animationSpeed, range: 0.4...2.0, format: "%.1fx")
            appearanceSlider("Saturation", value: $saturation, range: 0.6...1.8, format: "%.1f")
            Button("Restore appearance") {
                withAnimation(motionAnimation) {
                    glassOpacity = AppTheme.defaultGlassOpacity
                    wallpaperBlur = AppTheme.defaultWallpaperBlur
                    animationSpeed = AppTheme.defaultAnimationSpeed
                    saturation = AppTheme.defaultSaturation
                    accentPalette = AppAccentPalette.purple.rawValue
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(AppTheme.accent)
            .padding(.top, 4)
        }
    }

    private var referenceToolbar: some View {
        HStack(spacing: 0) {
            toolbarItem("house.fill", "Dashboard", selected: false)
            toolbarItem("scope", "Aimbot", selected: false)
            toolbarItem("eye.fill", "Visual", selected: false)
            toolbarItem("bolt.fill", "Misc", selected: false)
            toolbarItem("gearshape.fill", "Settings", selected: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.32) }
    }

    private func toolbarItem(_ systemImage: String, _ title: String, selected: Bool) -> some View {
        Button {
            if title == "Settings" { return }
            withAnimation(motionAnimation) { showAdvanced.toggle() }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: selected ? .bold : .medium))
                    .frame(width: selected ? 62 : 50, height: 34)
                    .background(selected ? AppTheme.accent.opacity(0.13) : .clear, in: Capsule())
                    .foregroundStyle(selected ? AppTheme.accent : Color(red: 0.56, green: 0.62, blue: 0.69))
                Text(title)
                    .font(.caption.weight(selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.accent : Color(red: 0.56, green: 0.62, blue: 0.69))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func referenceValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold))
                .foregroundStyle(ReferencePalette.ink)
        }
    }

    private func appearanceSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).tint(AppTheme.accent)
        }
        .padding(.top, 8)
    }
}

private enum ReferencePalette {
    static let ink = Color(red: 0.10, green: 0.08, blue: 0.29)
    static let background = Color(red: 0.965, green: 0.962, blue: 0.985)
}

private struct ReferenceBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            ReferencePalette.background
            Circle()
                .fill(AppTheme.accent.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 28)
                .offset(x: drift ? 150 : -140, y: drift ? -280 : -130)
            Circle()
                .fill(Color.white.opacity(0.80))
                .frame(width: 320, height: 320)
                .blur(radius: 34)
                .offset(x: drift ? -160 : 130, y: drift ? 340 : 220)
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

private struct ReferenceCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: { content })
            .padding(20)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.96), lineWidth: 1)
            }
            .shadow(color: AppTheme.accent.opacity(0.07), radius: 16, y: 7)
    }
}

private struct ReferenceSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(AppTheme.accent)
    }
}

private struct SupportBadge: View {
    let isSupported: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSupported ? Color(red: 0.08, green: 0.68, blue: 0.52) : .red)
                .frame(width: 9, height: 9)
            Text(isSupported ? "SUPPORTED" : "UNSUPPORTED")
                .font(.caption.weight(.bold))
                .tracking(0.7)
        }
        .foregroundStyle(isSupported ? Color(red: 0.05, green: 0.58, blue: 0.43) : .red)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            (isSupported ? Color(red: 0.82, green: 0.96, blue: 0.91) : Color.red.opacity(0.10)),
            in: Capsule()
        )
        .overlay(Capsule().stroke((isSupported ? Color.green : Color.red).opacity(0.25), lineWidth: 1))
    }
}

private struct ReferenceToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(configuration.isOn ? AppTheme.accent : Color.gray.opacity(0.28))
            .frame(width: 76, height: 36)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .padding(3)
                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.82), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityLabel(configuration.isOn ? "Ativado" : "Desativado")
    }
}
