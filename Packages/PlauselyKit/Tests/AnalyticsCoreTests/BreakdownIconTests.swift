import Foundation
import Testing

@testable import AnalyticsCore

@Suite("breakdown icons (05.x)")
struct BreakdownIconTests {
    @Test("source domains resolve to favicon hosts")
    func sourceDomains() {
        #expect(BreakdownIconResolver.hostForFavicon("chatgpt.com") == "chatgpt.com")
        #expect(BreakdownIconResolver.hostForFavicon("https://bing.com/search?q=1") == "bing.com")
        #expect(BreakdownIconResolver.hostForFavicon("bing.com/search") == "bing.com")
        #expect(BreakdownIconResolver.hostForFavicon("referrer-1.example.com/article") == "referrer-1.example.com")
        #expect(BreakdownIconResolver.hostForFavicon("example.com:8080/path") == "example.com")
        #expect(BreakdownIconResolver.hostForFavicon("HTTPS://EXAMPLE.COM") == "example.com")
    }

    @Test("brand names map to canonical hosts")
    func brandNames() {
        #expect(BreakdownIconResolver.hostForFavicon("Google") == "google.com")
        #expect(BreakdownIconResolver.hostForFavicon("Twitter") == "twitter.com")
        #expect(BreakdownIconResolver.hostForFavicon("ChatGPT") == "chatgpt.com")
        #expect(BreakdownIconResolver.hostForFavicon("DuckDuckGo") == "duckduckgo.com")
    }

    @Test("non-hosts yield no favicon")
    func nonHosts() {
        #expect(BreakdownIconResolver.hostForFavicon("Direct / None") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("Direct") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("   ") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("javascript:alert(1)") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("data:text/html,x") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("email") == nil)
        #expect(BreakdownIconResolver.hostForFavicon("/pricing") == nil)
    }

    @Test("sources prefer favicons, Direct uses a system icon")
    func sourceIcons() {
        #expect(BreakdownIconResolver.icon(forRowName: "chatgpt.com", kind: .sources) == .favicon(host: "chatgpt.com"))
        #expect(BreakdownIconResolver.icon(forRowName: "Google", kind: .sources) == .favicon(host: "google.com"))
        #expect(BreakdownIconResolver.icon(forRowName: "Direct", kind: .sources) == .system("keyboard"))
        #expect(BreakdownIconResolver.icon(forRowName: "Direct / None", kind: .sources) == .system("keyboard"))
        #expect(BreakdownIconResolver.icon(forRowName: "some-utm-tag", kind: .sources) == .system("tray.full.fill"))
    }

    @Test("referrer rows use host favicons")
    func referrerIcons() {
        let icon = BreakdownIconResolver.icon(
            forRowName: "bing.com/search", kind: .referrerDrilldown(referrer: "Bing")
        )
        #expect(icon == .favicon(host: "bing.com"))
    }

    @Test("channels map to distinct symbols")
    func channelIcons() {
        #expect(BreakdownIconResolver.icon(forRowName: "Organic Search", kind: .channels) == .system("magnifyingglass"))
        #expect(BreakdownIconResolver.icon(forRowName: "Direct", kind: .channels) == .system("keyboard"))
        #expect(BreakdownIconResolver.icon(forRowName: "Social", kind: .channels) == .system("person.2.fill"))
        #expect(BreakdownIconResolver.icon(forRowName: "Email", kind: .channels) == .system("envelope.fill"))
        #expect(BreakdownIconResolver.icon(forRowName: "Paid Search", kind: .channels) == .system("megaphone.fill"))
        #expect(BreakdownIconResolver.icon(forRowName: "Referral", kind: .channels) == .system("link"))
    }

    @Test("browsers and versions map per brand")
    func browserIcons() {
        #expect(BreakdownIconResolver.icon(forRowName: "Chrome", kind: .browsers) == .system("globe"))
        #expect(BreakdownIconResolver.icon(forRowName: "Safari", kind: .browsers) == .system("safari"))
        #expect(BreakdownIconResolver.icon(forRowName: "Firefox", kind: .browsers) == .system("flame"))
        #expect(BreakdownIconResolver.icon(forRowName: "Microsoft Edge", kind: .browsers) == .system("e.circle"))
        #expect(BreakdownIconResolver.icon(forRowName: "Chrome 119.0", kind: .browserVersions) == .system("globe"))
        #expect(BreakdownIconResolver.icon(forRowName: "Safari 17.1", kind: .browserVersions) == .system("safari"))
    }

    @Test("operating systems map per platform")
    func osIcons() {
        #expect(BreakdownIconResolver.icon(forRowName: "Mac", kind: .operatingSystems) == .system("laptopcomputer"))
        #expect(BreakdownIconResolver.icon(forRowName: "Windows", kind: .operatingSystems) == .system("desktopcomputer"))
        #expect(BreakdownIconResolver.icon(forRowName: "iOS", kind: .operatingSystems) == .system("iphone"))
        #expect(BreakdownIconResolver.icon(forRowName: "Android", kind: .operatingSystems) == .system("smartphone"))
        #expect(BreakdownIconResolver.icon(forRowName: "Linux", kind: .operatingSystems) == .system("terminal"))
        #expect(BreakdownIconResolver.icon(forRowName: "iOS 17.1", kind: .operatingSystemVersions) == .system("iphone"))
        #expect(BreakdownIconResolver.icon(forRowName: "Android 14", kind: .operatingSystemVersions) == .system("smartphone"))
        #expect(BreakdownIconResolver.icon(forRowName: "Mac 14.1", kind: .operatingSystemVersions) == .system("laptopcomputer"))
    }

    @Test("devices map per class")
    func deviceIcons() {
        #expect(BreakdownIconResolver.icon(forRowName: "Desktop", kind: .screenSizes) == .system("desktopcomputer"))
        #expect(BreakdownIconResolver.icon(forRowName: "Mobile", kind: .screenSizes) == .system("iphone"))
        #expect(BreakdownIconResolver.icon(forRowName: "Tablet", kind: .screenSizes) == .system("ipad"))
    }

    @Test("favicon URLs use the privacy-friendly proxy")
    func faviconURLs() {
        #expect(BreakdownIconResolver.faviconURL(forHost: "Google.COM")?.absoluteString == "https://icons.duckduckgo.com/ip3/google.com.ico")
        #expect(BreakdownIconResolver.faviconURL(forHost: "not a host") == nil)
        #expect(BreakdownIconResolver.faviconURL(forHost: "") == nil)
    }

    @Test("row convenience matches the string entry point")
    func rowConvenience() {
        let row = BreakdownRow(name: "chatgpt.com", metrics: [.visitors: .count(3)])
        #expect(BreakdownIconResolver.icon(for: row, kind: .sources) == .favicon(host: "chatgpt.com"))
    }
}
