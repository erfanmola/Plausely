import Foundation
import SwiftUI

/// App accent: Telegram-style colorway driving primary buttons, charts,
/// toggles, and links through the environment accent. Persisted choice,
/// blue default.
public enum AppAccent: String, CaseIterable, Codable, Sendable {
    case blue
    case green
    case purple
    case orange
    case pink
    case teal

    public var title: String {
        switch self {
        case .blue: return "Blue"
        case .green: return "Green"
        case .purple: return "Purple"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .teal: return "Teal"
        }
    }

    public var top: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.60, blue: 0.95)
        case .green: return Color(red: 0.25, green: 0.75, blue: 0.35)
        case .purple: return Color(red: 0.58, green: 0.34, blue: 0.95)
        case .orange: return Color(red: 1.00, green: 0.60, blue: 0.16)
        case .pink: return Color(red: 1.00, green: 0.30, blue: 0.45)
        case .teal: return Color(red: 0.15, green: 0.75, blue: 0.72)
        }
    }

    public var bottom: Color {
        switch self {
        case .blue: return Color(red: 0.02, green: 0.45, blue: 0.87)
        case .green: return Color(red: 0.12, green: 0.60, blue: 0.27)
        case .purple: return Color(red: 0.42, green: 0.20, blue: 0.88)
        case .orange: return Color(red: 0.95, green: 0.42, blue: 0.08)
        case .pink: return Color(red: 0.85, green: 0.12, blue: 0.35)
        case .teal: return Color(red: 0.05, green: 0.60, blue: 0.65)
        }
    }
}

/// App theme: system default or a forced light/dark look.
public enum AppTheme: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Shared appearance state: accent colorway plus theme override.
/// Persisted in UserDefaults; views read the singleton so switches
/// apply instantly everywhere.
@MainActor
@Observable
public final class AppAppearance {
    public static let shared = AppAppearance()

    public var accent: AppAccent {
        didSet { defaults.set(accent.rawValue, forKey: "plausely.appearance.accent") }
    }

    public var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "plausely.appearance.theme") }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let accentRaw = defaults.string(forKey: "plausely.appearance.accent")
        self.accent = AppAccent(rawValue: accentRaw ?? "") ?? .blue
        let themeRaw = defaults.string(forKey: "plausely.appearance.theme")
        self.theme = AppTheme(rawValue: themeRaw ?? "") ?? .system
    }
}

/// Telegram-style primary button: full-width, bold, gradient fill in the
/// current accent with a soft colored shadow and press squash.
public struct TelegramPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let accent = AppAppearance.shared.accent
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                LinearGradient(colors: [accent.top, accent.bottom], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
                    .mask {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)
                    }
            }
            .shadow(color: accent.bottom.opacity(0.4), radius: 14, y: 7)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}
