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
    case invalidCredentials
    case timedOut
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
        // Landing race: success (/sites), 2FA (/2fa), rejected credentials
        // (back on /login with an error flash), navigation errors, or a
        // 60s timeout. A rejected password previously hung here forever.
        let navigationError = NavigationErrorBox()
        let errorDelegate = FailOnlyDelegate(box: navigationError)
        retainers.append(errorDelegate)
        webView.navigationDelegate = errorDelegate
        let deadline = Date().addingTimeInterval(60)
        var landed = false
        while !landed {
            if let error = navigationError.error { throw error }
            let path = webView.url?.path() ?? ""
            if path.hasPrefix("/sites") {
                landed = true
            } else if path.contains("/2fa") {
                throw BridgeError.twoFactorRequired
            } else if path.hasSuffix("/login"), await loginRejected(webView) {
                throw BridgeError.invalidCredentials
            }
            if !landed {
                if Date() > deadline { throw BridgeError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        _ = landed
        retainers.removeAll()
        return await withCheckedContinuation { cont in
            config.websiteDataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    /// Dashboard rejection flash on a re-rendered login page.
    @MainActor
    private func loginRejected(_ webView: WKWebView) async -> Bool {
        (try? await webView.evaluateJavaScript(
            "(document.body ? document.body.innerText : '').match(/wrong email or password|invalid email|invalid credentials/i) !== null"
        )) as? Bool ?? false
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

/// Records navigation failures for the polling landing loop.
private final class NavigationErrorBox: @unchecked Sendable {
    var error: Error?
}

private final class FailOnlyDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    let box: NavigationErrorBox
    init(box: NavigationErrorBox) { self.box = box }
    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        if box.error == nil { box.error = error }
    }
    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        if box.error == nil { box.error = error }
    }
}
