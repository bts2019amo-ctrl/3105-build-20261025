import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(AppTheme.accentPaletteStorageKey)
    private var accentPalette = AppTheme.defaultAccentPalette
    @AppStorage(AppTheme.glassOpacityStorageKey)
    private var glassOpacity = AppTheme.defaultGlassOpacity
    @AppStorage(AppTheme.wallpaperBlurStorageKey)
    private var wallpaperBlur = AppTheme.defaultWallpaperBlur
    @AppStorage(AppTheme.animationSpeedStorageKey)
    private var animationSpeed = AppTheme.defaultAnimationSpeed
    @AppStorage(AppTheme.saturationStorageKey)
    private var saturation = AppTheme.defaultSaturation

    private var selectedPalette: AppAccentPalette {
        AppAccentPalette(rawValue: accentPalette) ?? .orange
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        AppTheme.accent.opacity(0.16),
                        Color(uiColor: .systemBackground).opacity(0.92),
                        AppTheme.accent.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        profileCard
                        languageCard
                        paletteCard
                        appearanceEditorCard
                        deviceCard
                        supportCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(AppTheme.accent)
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            AppLogo(size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("EXTERNAL SYSTEM")
                    .font(.title3.weight(.bold))
                Text(language.text("common.version", appVersion))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appState.isSupported ? .green : .red)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .glassCard()
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeader("settings.language", systemImage: "globe")
            Picker(language.text("settings.language"), selection: $languageCode) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(18)
        .glassCard()
    }

    private var paletteCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCardHeader("settings.palette", systemImage: "paintpalette.fill")
            Text(language.text("settings.palette_footer"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                ForEach(AppAccentPalette.allCases) { palette in
                    Button {
                        accentPalette = palette.rawValue
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(palette.color)
                                .frame(width: 38, height: 38)
                                .overlay {
                                    if palette == selectedPalette {
                                        Circle().stroke(.white, lineWidth: 3)
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .shadow(color: palette.color.opacity(0.32), radius: 8)
                            Text(language.text("settings.palette." + palette.rawValue))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            palette.color.opacity(palette == selectedPalette ? 0.16 : 0.06),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .glassCard()
    }

    private var appearanceEditorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCardHeader("settings.advanced_appearance", systemImage: "wand.and.stars")
            appearanceSlider("settings.glass_transparency", value: $glassOpacity, range: 0.05...0.30, format: "%.0f%%")
            appearanceSlider("settings.background_blur", value: $wallpaperBlur, range: 8...46, format: "%.0f")
            appearanceSlider("settings.animation_speed", value: $animationSpeed, range: 0.4...2.0, format: "%.1fx")
            appearanceSlider("settings.saturation", value: $saturation, range: 0.6...1.8, format: "%.1f")
            Button(language.text("settings.restore_appearance")) {
                glassOpacity = AppTheme.defaultGlassOpacity
                wallpaperBlur = AppTheme.defaultWallpaperBlur
                animationSpeed = AppTheme.defaultAnimationSpeed
                saturation = AppTheme.defaultSaturation
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
        }
        .padding(18)
        .glassCard()
    }

    private func appearanceSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.text(title)).font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .tint(AppTheme.accent)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeader("common.device", systemImage: "iphone")
            settingValue(language.text("dashboard.hardware_model"), AppInfo.displayMachineName)
            settingValue(language.text("settings.ios_version"), "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
        }
        .padding(18)
        .glassCard()
    }

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCardHeader("settings.verified_versions", systemImage: "checkmark.seal.fill")
            settingValue(
                language.text("settings.current_version"),
                language.text(appState.isSupported ? "settings.supported" : "settings.unsupported")
            )
            versionLine("iOS 17", ExploitSupportPolicy.verifiedIOS17Range)
            versionLine("iOS 18", ExploitSupportPolicy.verifiedIOS18Range)
            versionLine("iOS 26", ExploitSupportPolicy.verifiedIOS26Range)
            ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                versionLine("iOS 27", versionLabel(version))
            }
        }
        .padding(18)
        .glassCard()
    }

    private func settingsCardHeader(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(AppTheme.accent)
    }

    private func settingValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }

    private func versionLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private func versionLabel(
        _ version: (beta: Int, publicBeta: Int?, build: String)
    ) -> String {
        if let publicBeta = version.publicBeta {
            return language.text(
                "settings.developer_public_beta_build",
                Int64(version.beta),
                Int64(publicBeta),
                version.build
            )
        }
        return language.text("settings.developer_beta_build", Int64(version.beta), version.build)
    }
}

private extension View {
    func glassCard() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}
