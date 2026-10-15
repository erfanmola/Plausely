import AnalyticsCore
import SwiftUI

/// Theme and accent picker. Swatches preview each colorway gradient;
/// the theme segmented control overrides the system look.
public struct AppAppearanceView: View {
    @Bindable var appearance: AppAppearance

    public init(appearance: AppAppearance = AppAppearance.shared) {
        self.appearance = appearance
    }

    public var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-theme")
            } header: {
                Text("Theme")
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 14) {
                    ForEach(AppAccent.allCases, id: \.self) { accent in
                        Button {
                            appearance.accent = accent
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [accent.top, accent.bottom],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 52, height: 52)
                                if appearance.accent == accent {
                                    Image(systemName: "checkmark")
                                        .bold()
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(accent.title) accent")
                        .accessibilityIdentifier("appearance-accent-\(accent.rawValue)")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent color")
            } footer: {
                Text("Accents recolor buttons, charts, toggles, and links across the app.")
            }
        }
        .navigationTitle("Appearance")
        .sensoryFeedback(.selection, trigger: appearance.accent)
        .sensoryFeedback(.selection, trigger: appearance.theme)
    }
}
