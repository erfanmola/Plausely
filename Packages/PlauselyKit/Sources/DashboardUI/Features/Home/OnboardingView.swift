import Foundation
import SwiftUI

/// One-time introduction state. Plain `UserDefaults` backing; callers
/// inject an ephemeral suite in tests. Suppressed under UI-test launch
/// arguments so the login gate stays directly reachable there.
public struct OnboardingStore {
    private let defaults: UserDefaults
    private let key = "plausely.onboarding.seen.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasSeen: Bool {
        get { defaults.bool(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }

    /// UI-test launches bypass the intro so suites land on login directly.
    public static var suppressedForTests: Bool {
        CommandLine.arguments.contains("-plausely-live-reset")
            || CommandLine.arguments.contains("-plausely-mock")
            || CommandLine.arguments.contains("-plausely-mock-sites")
    }
}

/// Telegram-style introduction pager: swipeable slides with looping
/// native illustrations (no external animation dependencies), page dots,
/// Skip, and a final Get started. All motion freezes at its end state
/// under Reduce Motion.
public struct OnboardingView: View {
    private let onDone: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < 3 {
                    Button("Skip", action: onDone)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboarding-skip")
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            TabView(selection: $page) {
                OnboardingPage(
                    illustration: AnyView(ChartDrawIllustration()),
                    title: "Your traffic, beautifully clear",
                    subtitle: "Unique visitors, visits, and pageviews on one calm dashboard."
                )
                .tag(0)
                OnboardingPage(
                    illustration: AnyView(LivePulseIllustration()),
                    title: "See visitors right now",
                    subtitle: "A live headcount with a realtime chart that never sleeps."
                )
                .tag(1)
                OnboardingPage(
                    illustration: AnyView(BarsGrowIllustration()),
                    title: "Know where they come from",
                    subtitle: "Sources, pages, countries, and devices — tap any row to dig in."
                )
                .tag(2)
                OnboardingPage(
                    illustration: AnyView(ShieldIllustration()),
                    title: "Private by design",
                    subtitle: "Your instance only. Secrets stay in the Keychain, nothing is tracked."
                )
                .tag(3)
            }
#if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
#else
            .tabViewStyle(.automatic)
#endif
            .accessibilityIdentifier("onboarding-pager")
            // Custom dots: the native page indicator is unreliable here
            // (and absent on macOS), and these match the accent language.
            HStack(spacing: 8) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == page ? Color.accentColor : .secondary.opacity(0.3))
                        .frame(width: index == page ? 24 : 8, height: 8)
                        .animation(.snappy, value: page)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 8)
            .accessibilityIdentifier("onboarding-dots")
            Button(page < 3 ? "Continue" : "Get started", action: {
                if page < 3 {
                    withAnimation(.snappy) { page += 1 }
                } else {
                    onDone()
                }
            })
            .buttonStyle(TelegramPrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .accessibilityIdentifier(page < 3 ? "onboarding-next" : "onboarding-done")
            .sensoryFeedback(.selection, trigger: page)
            .animation(.snappy, value: reduceMotion)
        }
    }
}

private struct OnboardingPage: View {
    let illustration: AnyView
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            illustration
                .frame(height: 240)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2)
                .bold()
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }
}

/// Rising line chart that draws itself, then holds with a soft fill.
private struct ChartDrawIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    private let line = Path { path in
        path.move(to: CGPoint(x: 10, y: 150))
        path.addCurve(to: CGPoint(x: 90, y: 110), control1: CGPoint(x: 35, y: 140), control2: CGPoint(x: 60, y: 130))
        path.addCurve(to: CGPoint(x: 170, y: 70), control1: CGPoint(x: 120, y: 90), control2: CGPoint(x: 140, y: 100))
        path.addCurve(to: CGPoint(x: 250, y: 40), control1: CGPoint(x: 200, y: 40), control2: CGPoint(x: 220, y: 60))
    }

    var body: some View {
        ZStack {
            // Ghost of the full path so the frame always reads as a
            // chart, even at the start of each draw pass.
            line
                .stroke(.blue.opacity(0.15), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            line
                .trim(from: 0, to: reduceMotion ? 1 : progress)
                .stroke(.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 260, height: 170)
        .background {
            line
                .trim(from: 0, to: reduceMotion ? 1 : progress)
                .stroke(.blue.opacity(0.25), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .blur(radius: 14)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                progress = 1
            }
        }
    }
}

/// Presence dot with expanding rings and slow rising particles.
private struct LivePulseIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var time = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { graphics, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                for i in 0 ..< 14 {
                    let speed = 12 + Double(i % 5) * 5
                    let y = size.height - ((t * speed + Double(i) * 47).truncatingRemainder(dividingBy: size.height + 20)) + 10
                    let x = center.x + sin(Double(i) * 2.3 + t * 0.5) * (30 + Double(i % 4) * 14)
                    let alpha = max(0, 0.5 * (1 - (size.height - y) / size.height))
                    graphics.fill(
                        Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                        with: .color(.green.opacity(reduceMotion ? 0.25 : alpha))
                    )
                }
                for ring in 0 ..< 3 {
                    let phase = reduceMotion ? 0.6 : ((t * 0.5 + Double(ring) / 3).truncatingRemainder(dividingBy: 1))
                    graphics.stroke(
                        Path(ellipseIn: CGRect(
                            x: center.x - 14 - phase * 46, y: center.y - 14 - phase * 46,
                            width: 28 + phase * 92, height: 28 + phase * 92
                        )),
                        with: .color(.green.opacity(0.5 * (1 - phase))),
                        lineWidth: 3
                    )
                }
                graphics.fill(
                    Path(ellipseIn: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)),
                    with: .color(.green)
                )
            }
        }
        .frame(width: 260, height: 170)
    }
}

/// Breakdown bars growing in with a stagger, then holding.
private struct BarsGrowIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0
    private let widths: [CGFloat] = [1, 0.82, 0.64, 0.45, 0.3]

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, fraction in
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(40, proxy.size.width * fraction * barScale(index: index)))
                        .frame(height: 26)
                }
                .frame(height: 26)
            }
        }
        .frame(width: 260, height: 170)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func barScale(index: Int) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let local = max(0, min(1, phase * 1.6 - Double(index) * 0.12))
        return 0.15 + 0.85 * local
    }
}

/// Privacy shield breathing gently.
private struct ShieldIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        Image(systemName: "lock.shield.fill")
            .font(.system(size: 110))
            .foregroundStyle(.green.gradient)
            .symbolEffect(.bounce, value: breathe)
            .scaleEffect(breathe ? 1.04 : 1)
            .frame(width: 260, height: 170)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}
