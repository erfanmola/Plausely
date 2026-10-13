import Foundation

/// Row icon: either a remote favicon for a host or a local SF Symbol.
/// Favicons use DuckDuckGo's icon service (`icons.duckduckgo.com`), a
/// privacy-friendly proxy in the Plausible spirit: no Google tracking
/// pixel, no API key, and the app never guesses artwork for brands.
/// System symbols cover non-host rows (Direct, channels, browsers, OS,
/// devices) where no favicon exists by construction.
public enum BreakdownIcon: Hashable, Sendable {
    case favicon(host: String)
    case system(String)
}

/// Pure resolver for breakdown row artwork. No networking, no cache, no
/// date math: given a row name + family, it answers favicon-host vs
/// system symbol deterministically, so SwiftUI and tests share one truth.
public enum BreakdownIconResolver {
    /// Favicon service base. Host is lowercased before interpolation.
    public static func faviconURL(forHost host: String) -> URL? {
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isPlausibleHost(cleaned) else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(cleaned).ico")
    }

    /// Icon for one row in a family.
    public static func icon(for row: BreakdownRow, kind: ReportKind) -> BreakdownIcon {
        icon(forRowName: row.name, kind: kind)
    }

    /// String-level entry point (tests + previews without full rows).
    public static func icon(forRowName name: String, kind: ReportKind) -> BreakdownIcon {
        switch kind {
        case .sources:
            return sourceIcon(name)
        case .referrerDrilldown:
            if let host = hostForFavicon(name) {
                return .favicon(host: host)
            }
            return .system("link")
        case .channels:
            return .system(channelSymbol(for: name))
        case .browsers, .browserVersions:
            return .system(browserSymbol(for: name))
        case .operatingSystems, .operatingSystemVersions:
            return .system(osSymbol(for: name))
        case .screenSizes:
            return .system(deviceSymbol(for: name))
        case .pages:
            return .system("doc.fill")
        case .entryPages:
            return .system("arrow.right.to.line")
        case .exitPages:
            return .system("arrow.left.to.line")
        case .countries:
            return .system("globe")
        case .regions:
            return .system("map.fill")
        case .cities:
            return .system("building.2.fill")
        case .utmMediums, .utmSources, .utmCampaigns, .utmContents, .utmTerms:
            return .system("tag.fill")
        case .conversions:
            return .system("flag.checkered")
        case .customPropValues:
            return .system("slider.horizontal.3")
        case .suggestions:
            return .system("magnifyingglass")
        case .searchTerms:
            return .system("magnifyingglass")
        }
    }

    // MARK: - Sources

    private static func sourceIcon(_ name: String) -> BreakdownIcon {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if directNames.contains(lower) {
            return .system("keyboard")
        }
        if let host = hostForFavicon(trimmed) {
            return .favicon(host: host)
        }
        return .system("tray.full.fill")
    }

    /// Host for a favicon fetch, or nil when the name carries no host.
    /// Accepts bare hosts (`chatgpt.com`), URLs
    /// (`https://bing.com/search?q=1`), host+path (`bing.com/search`),
    /// ports (`example.com:8080/path`), and well-known brand names
    /// (`Google` -> `google.com`). Anything without a dot after brand
    /// resolution (UTM tags, channel names, `(not set)`) yields nil.
    public static func hostForFavicon(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if directNames.contains(lower) { return nil }
        if let brand = brandHosts[lower] { return brand }
        // Strip scheme when present.
        var candidate = trimmed
        if let range = candidate.range(of: "://") {
            candidate = String(candidate[range.upperBound...])
            // Reject non-web schemes that slipped through without Early exit:
            // hostForFavicon only runs on names without "://" after brand
            // lookup except bare-host fast paths; a scheme here means the
            // original carried one, and only http(s) may proceed.
            let scheme = trimmed[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        } else if candidate.contains(":") && !candidate.contains(".") {
            // `javascript:…`, `data:…`, `myapp:…` — never a host.
            return nil
        }
        // Cut path / query / fragment.
        for separator in ["/", "?", "#"] as [Character] {
            if let index = candidate.firstIndex(of: separator) {
                candidate = String(candidate[..<index])
            }
        }
        // Strip port, credentials, trailing dot.
        if let atIndex = candidate.lastIndex(of: "@") {
            candidate = String(candidate[candidate.index(after: atIndex)...])
        }
        if let colonIndex = candidate.firstIndex(of: ":") {
            candidate = String(candidate[..<colonIndex])
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard isPlausibleHost(candidate) else { return nil }
        // Second brand pass: `Google / organic` style suffixes never reach
        // here (no dot), but `google.com`-shaped candidates pass as-is.
        return candidate
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.contains("."), !host.contains(" "),
              !host.hasPrefix("-"), !host.hasSuffix("-"),
              !host.hasPrefix("."), !host.hasSuffix(".")
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let directNames: Set<String> = [
        "direct", "direct / none", "direct/none", "(direct)", "(none)",
        "none", "direct traffic", "(not set)",
    ]

    /// Brand name (lowercased) to canonical host. Covers Plausible's
    /// top source labels that arrive without a TLD.
    private static let brandHosts: [String: String] = [
        // Search
        "google": "google.com", "bing": "bing.com",
        "duckduckgo": "duckduckgo.com", "yahoo": "yahoo.com",
        "ecosia": "ecosia.org", "brave": "brave.com",
        "brave search": "search.brave.com", "yandex": "yandex.com",
        "baidu": "baidu.com", "naver": "naver.com",
        "seznam": "seznam.cz", "qwant": "qwant.com",
        "mojeek": "mojeek.com", "startpage": "startpage.com",
        "swisscows": "swisscows.com", "aol": "aol.com",
        "ask": "ask.com", "perplexity": "perplexity.ai",
        // Social
        "facebook": "facebook.com", "instagram": "instagram.com",
        "twitter": "twitter.com", "x": "x.com",
        "linkedin": "linkedin.com", "reddit": "reddit.com",
        "youtube": "youtube.com", "tiktok": "tiktok.com",
        "pinterest": "pinterest.com", "snapchat": "snapchat.com",
        "tumblr": "tumblr.com", "twitch": "twitch.tv",
        "discord": "discord.com", "telegram": "telegram.org",
        "whatsapp": "whatsapp.com", "threads": "threads.net",
        "bluesky": "bsky.app", "mastodon": "mastodon.social",
        "medium": "medium.com", "substack": "substack.com",
        "hacker news": "news.ycombinator.com",
        "product hunt": "producthunt.com",
        "indie hackers": "indiehackers.com", "dev.to": "dev.to",
        "quora": "quora.com", "vimeo": "vimeo.com",
        "dribbble": "dribbble.com", "behance": "behance.net",
        "flickr": "flickr.com", "github community": "github.com",
        // Dev
        "github": "github.com", "gitlab": "gitlab.com",
        "stackoverflow": "stackoverflow.com",
        "stack overflow": "stackoverflow.com",
        "stackexchange": "stackexchange.com",
        "codepen": "codepen.io", "jsfiddle": "jsfiddle.net",
        "npm": "npmjs.com", "pypi": "pypi.org",
        // AI
        "chatgpt": "chatgpt.com", "openai": "openai.com",
        "claude": "claude.ai", "gemini": "gemini.google.com",
        "copilot": "copilot.microsoft.com",
        "microsoft copilot": "copilot.microsoft.com",
        "grok": "grok.com", "deepseek": "deepseek.com",
        "meta ai": "meta.ai",
        // Mail / messaging
        "gmail": "mail.google.com", "outlook": "outlook.live.com",
        "hotmail": "outlook.live.com", "yahoo mail": "mail.yahoo.com",
        "protonmail": "proton.me", "hey": "hey.com",
        "fastmail": "fastmail.com", "slack": "slack.com",
        // Misc referrers
        "wordpress": "wordpress.com", "notion": "notion.so",
        "figma": "figma.com", "canva": "canva.com",
        "shopify": "shopify.com", "stripe": "stripe.com",
        "zoom": "zoom.us", "teams": "teams.microsoft.com",
    ]

    // MARK: - Family symbols

    private static func channelSymbol(for name: String) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case let value where value.contains("organic"):
            return "magnifyingglass"
        case let value where value.contains("direct"):
            return "keyboard"
        case let value where value.contains("social"):
            return "person.2.fill"
        case let value where value.contains("email"):
            return "envelope.fill"
        case let value where value.contains("paid") || value.contains("ads") || value.contains("cpc"):
            return "megaphone.fill"
        case let value where value.contains("referral"):
            return "link"
        case let value where value.contains("display"):
            return "rectangle.on.rectangle"
        case let value where value.contains("affiliate"):
            return "person.crop.circle.badge.checkmark"
        default:
            return "antenna.radiowaves.left.and.right"
        }
    }

    private static func browserSymbol(for name: String) -> String {
        let base = name.split(separator: " ").first.map(String.init)?.lowercased()
            ?? name.lowercased()
        switch base {
        case "safari": return "safari"
        case "chrome": return "globe"
        case "firefox": return "flame"
        case "edge", "microsoft": return "e.circle"
        case "opera": return "o.circle"
        case "brave": return "shield"
        case "vivaldi": return "v.circle"
        case "arc": return "a.circle"
        case "samsung", "samsung internet": return "smartphone"
        case "yandex": return "y.circle"
        case "chromium": return "globe"
        case "(not", "(none)": return "questionmark"
        default:
            if name.lowercased().contains("samsung") { return "smartphone" }
            if name.lowercased().contains("edge") { return "e.circle" }
            if name.lowercased().contains("opera") { return "o.circle" }
            return "globe"
        }
    }

    private static func osSymbol(for name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("(not") || lower == "(none)" { return "questionmark" }
        if lower.hasPrefix("mac") || lower.contains("macos") { return "laptopcomputer" }
        if lower.contains("windows") { return "desktopcomputer" }
        if lower.hasPrefix("ios") || lower.hasPrefix("iphone") || lower.hasPrefix("ipad") {
            return lower.contains("ipad") ? "ipad" : "iphone"
        }
        if lower.contains("android") { return "smartphone" }
        if lower.contains("linux") || lower.contains("ubuntu")
            || lower.contains("fedora") || lower.contains("debian") { return "terminal" }
        if lower.contains("chrome os") || lower.contains("chromeos") { return "laptopcomputer" }
        if lower.contains("watch") || lower.contains("watchos") { return "applewatch" }
        if lower.contains("tv") || lower.contains("tvos") { return "tv" }
        return "desktopcomputer"
    }

    private static func deviceSymbol(for name: String) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "desktop": return "desktopcomputer"
        case "mobile": return "iphone"
        case "tablet": return "ipad"
        case "tv", "smart tv": return "tv"
        case "console", "game console": return "gamecontroller"
        case "watch", "wearable": return "applewatch"
        case "(not set)", "(none)": return "questionmark"
        default: return "macwindow"
        }
    }
}
