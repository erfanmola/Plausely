import AnalyticsCore
import Foundation

/// Pinned sites, persisted per account in order of pinning. Plain
/// `UserDefaults` backing (no server round-trip, no Keychain secrets);
/// callers inject an ephemeral suite in tests. Main-actor confined
/// through its owners.
public struct PinnedSites {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for account: AccountID) -> String {
        "plausely.pinned.\(account.rawValue.uuidString)"
    }

    public func pinnedDomains(account: AccountID) -> [String] {
        defaults.stringArray(forKey: key(for: account)) ?? []
    }

    public func isPinned(domain: String, account: AccountID) -> Bool {
        pinnedDomains(account: account).contains(domain)
    }

    public func setPinned(_ pinned: Bool, domain: String, account: AccountID) {
        var current = pinnedDomains(account: account)
        current.removeAll { $0 == domain }
        if pinned { current.append(domain) }
        defaults.set(current, forKey: key(for: account))
    }
}
