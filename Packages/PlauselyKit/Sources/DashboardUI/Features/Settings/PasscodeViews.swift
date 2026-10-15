import AnalyticsCore
import SwiftUI

/// Telegram-style passcode pad: full-bleed blue, white lock, progress
/// dots, round translucent keys with ABC sublabels, delete key, and an
/// optional biometric shortcut. One view serves unlock, first entry,
/// repeat entry, and verify-before-change through `purpose`; completed
/// 4-digit entries report through `onComplete` and never persist here.
public struct PasscodeView: View {
    public enum Purpose: Sendable {
        case unlock
        case setFirst
        case setRepeat(first: String)
        case verify(title: String)
    }

    private let purpose: Purpose
    private let biometricKind: AppLockModel.BiometricKind
    private let showsBiometric: Bool
    private let shakeAttempts: Int
    private let onComplete: (String) -> Void
    private let onCancel: () -> Void
    private let onBiometric: () -> Void

    @State private var entry = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        purpose: Purpose,
        biometricKind: AppLockModel.BiometricKind = .none,
        showsBiometric: Bool = false,
        shakeAttempts: Int = 0,
        onComplete: @escaping (String) -> Void = { _ in },
        onCancel: @escaping () -> Void = {},
        onBiometric: @escaping () -> Void = {}
    ) {
        self.purpose = purpose
        self.biometricKind = biometricKind
        self.showsBiometric = showsBiometric
        self.shakeAttempts = shakeAttempts
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onBiometric = onBiometric
    }

    private var title: String {
        switch purpose {
        case .unlock: return "Enter passcode"
        case .setFirst: return "Set a passcode"
        case .setRepeat: return "Repeat the passcode"
        case .verify(let title): return title
        }
    }

    private var biometricName: String {
        switch biometricKind {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "faceid"
        }
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.2, green: 0.6, blue: 0.95), Color(red: 0.0, green: 0.45, blue: 0.86)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .padding(.top, 72)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(.top, 28)
                    .accessibilityIdentifier("applock-title")
                dots
                    .padding(.top, 22)
                    .modifier(ShakeEffect(attempts: reduceMotion ? 0 : shakeAttempts))
                    .animation(.linear(duration: 0.4), value: shakeAttempts)
                Spacer(minLength: 24)
                pad
                    .padding(.horizontal, 56)
                    .padding(.bottom, 12)
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 32)
                    .accessibilityIdentifier("applock-cancel")
            }
        }
        .background {
            // Hardware keyboard path (macOS only): an invisible focused
            // field mirrors physical typing into the pad state. On iOS
            // this would summon the software keyboard over the pad.
#if os(macOS)
            TextField("", text: $entry)
                .focused($fieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
                .onAppear { fieldFocused = true }
                .onChange(of: entry) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(4))
                    if digits != value { entry = digits }
                }
#endif
        }
        .onChange(of: entry) { _, value in
            if value.count == 4 {
                let code = value
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    onComplete(code)
                    entry = ""
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: entry)
    }

    private var dots: some View {
        HStack(spacing: 26) {
            ForEach(0 ..< 4, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? Color.white : Color.clear)
                    .frame(width: 15, height: 15)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private var pad: some View {
        VStack(spacing: 22) {
            ForEach(0 ..< 3, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(1 ... 3, id: \.self) { column in
                        let digit = row * 3 + column
                        key(String(digit), sublabel: Self.sublabel(digit))
                    }
                }
            }
            HStack(spacing: 26) {
                if showsBiometric, biometricKind != .none {
                    Button(action: onBiometric) {
                        Image(systemName: biometricName)
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Color.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock with biometrics")
                    .accessibilityIdentifier("applock-biometric")
                } else {
                    Color.clear.frame(width: 84, height: 84)
                }
                key("0", sublabel: nil)
                Button {
                    if !entry.isEmpty { entry.removeLast() }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
                .accessibilityIdentifier("applock-delete")
            }
        }
    }

    private func key(_ digit: String, sublabel: String?) -> some View {
        Button {
            if entry.count < 4 { entry.append(digit) }
        } label: {
            VStack(spacing: 0) {
                Text(digit)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
                if let sublabel {
                    Text(sublabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: 84, height: 84)
            .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Digit \(digit)")
    }

    private static func sublabel(_ digit: Int) -> String? {
        switch digit {
        case 2: return "ABC"
        case 3: return "DEF"
        case 4: return "GHI"
        case 5: return "JKL"
        case 6: return "MNO"
        case 7: return "PQRS"
        case 8: return "TUV"
        case 9: return "WXYZ"
        default: return nil
        }
    }
}

/// Wrong-code shake: classic spring translation driven by the attempt
/// count. Skipped under Reduce Motion by the caller.
struct ShakeEffect: GeometryEffect {
    var attempts: Int

    var animatableData: CGFloat {
        get { CGFloat(attempts) }
        set { attempts = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 10 * sin(animatableData * .pi * 3),
            y: 0
        ))
    }
}

/// Full-screen gate: covers live content with the unlock pad while the
/// model reports locked. Overlays instead of presenting so both platforms
/// share one path with no presentation-API gaps.
public struct AppLockGate<Content: View>: View {
    @Bindable var model: AppLockModel
    private let content: () -> Content

    public init(model: AppLockModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self.content = content
    }

    public var body: some View {
        ZStack {
            content()
            if model.isLocked, model.isEnabled {
                PasscodeView(
                    purpose: .unlock,
                    biometricKind: model.biometricKind,
                    showsBiometric: model.biometricEnabled,
                    shakeAttempts: model.failedAttempts,
                    onComplete: { _ = model.unlock(passcode: $0) },
                    onBiometric: { Task { await model.unlockWithBiometrics() } }
                )
                .transition(.opacity)
                .ignoresSafeArea()
                .task {
                    if model.biometricEnabled {
                        _ = await model.unlockWithBiometrics()
                    }
                }
            }
        }
        .animation(.snappy, value: model.isLocked)
    }
}

/// Passcode & biometrics settings: enable with a set-and-repeat flow,
/// change behind a verify step, disable behind verification, and the
/// biometric shortcut toggle. Wrong codes shake with an error tick.
public struct AppLockSettingsView: View {
    @Bindable var model: AppLockModel
    @State private var flow: Flow?
    @State private var firstEntry = ""
    @State private var localError: String?

    private enum Flow: Identifiable {
        case setupFirst
        case setupRepeat(first: String)
        case verifyDisable
        case verifyChange

        var id: String {
            switch self {
            case .setupFirst: return "setup"
            case .setupRepeat: return "repeat"
            case .verifyDisable: return "disable"
            case .verifyChange: return "change"
            }
        }
    }

    public init(model: AppLockModel) {
        self.model = model
    }

    private var biometricTitle: String {
        switch model.biometricKind {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "Biometric unlock"
        }
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Passcode", isOn: passcodeBinding)
                    .accessibilityIdentifier("applock-passcode-toggle")
            } footer: {
                Text("Locks Plausely on every launch and when it leaves the screen. Widgets stay visible.")
            }
            if model.isEnabled {
                Section {
                    Toggle(biometricTitle, isOn: biometricBinding)
                        .disabled(model.biometricKind == .none)
                        .accessibilityIdentifier("applock-biometric-toggle")
                    Button("Change passcode") { flow = .verifyChange }
                        .accessibilityIdentifier("applock-change")
                }
            }
            if let localError {
                Section {
                    Text(localError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("applock-error")
                }
            }
        }
        .navigationTitle("Passcode & Face ID")
        .sheet(item: $flow) { flow in
            switch flow {
            case .setupFirst:
                PasscodeView(
                    purpose: .setFirst,
                    shakeAttempts: model.failedAttempts,
                    onComplete: { firstEntry = $0; self.flow = .setupRepeat(first: $0) },
                    onCancel: { self.flow = nil }
                )
            case .setupRepeat(let first):
                PasscodeView(
                    purpose: .setRepeat(first: first),
                    shakeAttempts: model.failedAttempts,
                    onComplete: { second in
                        if second == first {
                            try? model.setup(passcode: second, biometric: model.biometricEnabled)
                            localError = nil
                            self.flow = nil
                        } else {
                            localError = "Codes don't match. Start over."
                            self.flow = .setupFirst
                        }
                    },
                    onCancel: { self.flow = nil }
                )
            case .verifyDisable:
                PasscodeView(
                    purpose: .verify(title: "Enter passcode to turn it off"),
                    shakeAttempts: model.failedAttempts,
                    onComplete: { code in
                        if model.unlock(passcode: code) {
                            try? model.disable()
                            localError = nil
                            self.flow = nil
                        }
                    },
                    onCancel: { self.flow = nil }
                )
            case .verifyChange:
                PasscodeView(
                    purpose: .verify(title: "Enter your current passcode"),
                    shakeAttempts: model.failedAttempts,
                    onComplete: { code in
                        if model.unlock(passcode: code) {
                            self.flow = .setupFirst
                        }
                    },
                    onCancel: { self.flow = nil }
                )
            }
        }
        .sensoryFeedback(.error, trigger: model.failedAttempts)
        .onAppear { model.refreshBiometry() }
    }

    private var passcodeBinding: Binding<Bool> {
        Binding(
            get: { model.isEnabled },
            set: { on in
                if on {
                    firstEntry = ""
                    flow = .setupFirst
                } else {
                    flow = .verifyDisable
                }
            }
        )
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { model.biometricEnabled },
            set: { try? model.setBiometric($0) }
        )
    }
}
