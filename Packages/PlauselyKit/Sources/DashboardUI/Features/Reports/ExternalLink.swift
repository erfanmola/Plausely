import Foundation

/// Safe external links (ACQ-03/Page rows): only `http`/`https` URLs with a
/// host ever render an Open action. Everything else — javascript:/data:/
 /// file: URLs, custom schemes, protocol-relative and empty strings — never
/// becomes a tappable link. Matching is case-insensitive on the scheme.
public enum ExternalLinkGate {
    /// Validated openable URL for a row name, or nil when the row must not
    /// offer an Open action. Bare hostnames gain an `https` scheme; names
    /// that already carry a non-web scheme are rejected, never rewritten.
    public static func url(for name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil, !(url.host?.isEmpty ?? true)
            else { return nil }
            return url
        }
        guard !trimmed.hasPrefix("/") else { return nil }
        guard let url = URL(string: "https://\(trimmed)"), url.host != nil else { return nil }
        return url
    }
}
