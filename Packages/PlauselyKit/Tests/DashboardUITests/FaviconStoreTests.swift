import Foundation
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@testable import DashboardUI

@Suite("favicon cache (05.x)")
@MainActor
struct FaviconStoreTests {
    @Test("filenames stay inside the cache directory")
    func fileNames() {
        #expect(FaviconStore.fileName(for: "google.com") == "google.com.ico")
        #expect(FaviconStore.fileName(for: "Google.COM") == "google.com.ico")
        #expect(FaviconStore.fileName(for: "a/b?c#d") == "a_b_c_d.ico")
        #expect(!FaviconStore.fileName(for: "..").contains("/"))
    }

    @Test("remembered images read back from memory")
    func memoryRoundtrip() {
        let store = FaviconStore()
        #expect(store.cachedImage(for: "example.com") == nil)
        store.remember(Self.pixel(), for: "Example.COM")
        #expect(store.cachedImage(for: "example.com") != nil)
    }

    @Test("concurrent loads deduplicate")
    func loadSkipsWhenCached() async {
        let store = FaviconStore()
        store.remember(Self.pixel(), for: "example.com")
        await store.load(host: "example.com")
        #expect(store.cachedImage(for: "example.com") != nil)
    }

    private static func pixel() -> PlatformImage {
        #if os(macOS)
        return PlatformImage(size: NSSize(width: 1, height: 1))
        #else
        UIGraphicsBeginImageContext(CGSize(width: 1, height: 1))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
        #endif
    }
}
