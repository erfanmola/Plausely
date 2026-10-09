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

/// One proportional bar row: lavender fill sized by share of the top value,
/// name (plus optional flag) at leading, exact value at trailing. The fill
/// is decorative; name and value stay real text for VoiceOver.
struct HomeBarRow: View {
    let name: String
    let flag: String?
    let valueText: String
    let fraction: Double
    let prefix: String
    let index: Int

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { proxy in
                Capsule(style: .continuous)
                    .fill(HomeStyle.barFill)
                    .frame(width: max(56, proxy.size.width * max(0, min(1, fraction))), height: 46)
                    .accessibilityHidden(true)
            }
            .frame(height: 46)
            HStack(spacing: 8) {
                if let flag {
                    Text(flag)
                        .accessibilityHidden(true)
                }
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(valueText)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-\(index)")
    }
}

/// Capsule control treatment: Liquid Glass where the floor allows it,
/// the card capsule before that. Content supplies its own padding; the
/// shape hugs it either way.
extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(HomeStyle.card, in: Capsule(style: .continuous))
        }
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
