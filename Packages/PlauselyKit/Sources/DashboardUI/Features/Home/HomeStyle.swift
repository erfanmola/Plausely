import AnalyticsCore
import SwiftUI

/// Home design tokens: grouped canvas, elevated cards, capsule pills.
/// System colors throughout so light/dark follow the device.
enum HomeStyle {
    static var page: Color {
#if os(iOS)
        Color(.systemGroupedBackground)
#else
        Color(nsColor: .windowBackgroundColor)
#endif
    }

    static var card: Color {
#if os(iOS)
        Color(.secondarySystemGroupedBackground)
#else
        Color(nsColor: .controlBackgroundColor)
#endif
    }

    static var barFill: Color { .accentColor.opacity(0.15) }
    static var corner: CGFloat { 22 }
}

/// Elevated white card shared by every home section.
struct HomeCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: HomeStyle.corner, style: .continuous))
    }
}

/// Capsule pill button (site/period pickers): label-only content in a card
/// capsule. Haptic-free; menus handle their own feedback.
struct HomePill<Label: View, MenuItems: View>: View {
    private let label: Label
    private let menuItems: MenuItems
    private let identifier: String

    init(
        identifier: String,
        @ViewBuilder label: () -> Label,
        @ViewBuilder menuItems: () -> MenuItems
    ) {
        self.identifier = identifier
        self.label = label()
        self.menuItems = menuItems()
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            label
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(HomeStyle.card, in: Capsule(style: .continuous))
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Capsule control treatment: frosted system material on every floor.
/// (Liquid Glass `glassEffect` needs the iOS 26 SDK, which our CI
/// toolchain lacks — materials render natively everywhere instead.)
extension View {
    func glassCapsule() -> some View {
        self.background(.thinMaterial, in: Capsule(style: .continuous))
    }
}

/// Frosted-glass tile for glyph marks (monograms): system material on
/// every floor, quiet system fill only where materials can't go.
extension View {
    func glassTile(cornerRadius: CGFloat = 12) -> some View {
        self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Bold card title used by every home family card.
struct HomeCardTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3)
            .bold()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }
}
