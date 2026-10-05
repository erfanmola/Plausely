import AnalyticsCore
import Foundation
import WebKit

/// Interactive login bridge: isolated non-persistent WKWebView sign-in.
/// Productized from the phase-00 spike (proven on macOS and iOS simulator).
/// CSRF flows inside the native form submit exactly like the browser; the
/// caller never handles tokens or passwords beyond this call.
public protocol WebLoginBridge: Sendable {
    func loginCookies(email: String, password: String) async throws -> [HTTPCookie]
}

public enum BridgeError: Error, Equatable {
    case formFillFailed(String)
    case twoFactorRequired
    case unexpectedLanding(String?)
}

/// First-party login through `baseURL` with per-call isolated storage.
/// Nothing persists: the caller decides what to keep via `CredentialStore`.
public struct WebAuthenticationBridge: WebLoginBridge, Sendable {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }

    @MainActor
    public func loginCookies(email: String, password: String) async throws -> [HTTPCookie] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)
        var retainers: [WKNavigationDelegate] = []
        let loginURL = baseURL.appending(path: "login")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = FinishDelegate { cont.resume() } onFail: { cont.resume(throwing: $0) }
            retainers.append(delegate)
            webView.navigationDelegate = delegate
            webView.load(URLRequest(url: loginURL))
        }
        retainers.removeAll()
        let fill = """
        (() => {
          const e = document.querySelector('input[type="email"]');
          const p = document.querySelector('input[type="password"]');
          if (!e || !p) return 'missing-fields';
          e.value = \(jsString(email));
          p.value = \(jsString(password));
          e.dispatchEvent(new Event('input', {bubbles: true}));
          p.dispatchEvent(new Event('input', {bubbles: true}));
          const f = e.form;
          if (!f) return 'missing-form';
          f.requestSubmit();
          return 'submitted';
        })()
        """
        let fillResult = try await webView.evaluateJavaScript(fill) as? String
        guard fillResult == "submitted" else {
            throw BridgeError.formFillFailed(String(describing: fillResult))
        }
        let landed: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let delegate = LandingDelegate(
                successPrefix: "/sites",
                twoFactorPrefix: "/2fa",
                onSuccess: { cont.resume(returning: "sites") },
                onTwoFactor: { cont.resume(throwing: BridgeError.twoFactorRequired) },
                onFail: { cont.resume(throwing: $0) }
            )
            retainers.append(delegate)
            webView.navigationDelegate = delegate
        }
        retainers.removeAll()
        _ = landed
        return await withCheckedContinuation { cont in
            config.websiteDataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    private func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "'\(escaped)'"
    }
}

private final class FinishDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    let resume: () -> Void
    let fail: (Error) -> Void
    init(_ resume: @escaping () -> Void, onFail: @escaping (Error) -> Void) {
        self.resume = resume; self.fail = onFail
    }
    func webView(_: WKWebView, didFinish _: WKNavigation!) { resume() }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) { fail(error) }
}

private final class LandingDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    let successPrefix: String
    let twoFactorPrefix: String
    let onSuccess: () -> Void
    let onTwoFactor: () -> Void
    let onFail: (Error) -> Void
    var done = false
    init(successPrefix: String, twoFactorPrefix: String, onSuccess: @escaping () -> Void, onTwoFactor: @escaping () -> Void, onFail: @escaping (Error) -> Void) {
        self.successPrefix = successPrefix; self.twoFactorPrefix = twoFactorPrefix
        self.onSuccess = onSuccess; self.onTwoFactor = onTwoFactor; self.onFail = onFail
    }
    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        guard !done, let path = webView.url?.path() else { return }
        if path.hasPrefix(successPrefix) { done = true; onSuccess() }
        else if path.contains(twoFactorPrefix) { done = true; onTwoFactor() }
    }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        if !done { done = true; onFail(error) }
    }
}
