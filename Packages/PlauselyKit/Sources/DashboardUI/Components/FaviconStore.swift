import AnalyticsCore
import SwiftUI
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Disk + memory cache for breakdown favicons. `AsyncImage` refetches on
/// every launch with no disk persistence; this store keeps one `.ico` per
/// host in the caches directory (30-day freshness) plus an `NSCache`
/// hot set, so breakdowns render instantly and work offline after first
/// sight. Keyed by lowercased host; invalid hosts never reach the network
/// (the resolver rejects them first, belt-and-braces rechecked here).
@MainActor
public final class FaviconStore: ObservableObject {
    public static let shared = FaviconStore()

    @Published public private(set) var images: [String: PlatformImage] = [:]

    private let memory = NSCache<NSString, PlatformImage>()
    private let session: URLSession
    private var inFlight: Set<String> = []
    private let freshness: TimeInterval = 30 * 24 * 3600

    public init(session: URLSession = .shared) {
        self.session = session
        memory.countLimit = 300
    }

    public func cachedImage(for host: String) -> PlatformImage? {
        let key = host.lowercased()
        if let image = images[key] { return image }
        if let image = memory.object(forKey: key as NSString) {
            images[key] = image
            return image
        }
        if let image = readDisk(for: key) {
            memory.setObject(image, forKey: key as NSString)
            images[key] = image
            return image
        }
        return nil
    }

    /// Fetches and caches the favicon unless already held or loading.
    /// Failures are silent: the row keeps its family-symbol fallback.
    public func load(host: String) async {
        let key = host.lowercased()
        guard cachedImage(for: key) == nil, !inFlight.contains(key) else { return }
        guard let url = BreakdownIconResolver.faviconURL(forHost: key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200,
                  !data.isEmpty, let image = PlatformImage(data: data)
            else { return }
            remember(image, for: key, persist: data)
        } catch {
            return
        }
    }

    // MARK: - Seams for tests

    public func remember(_ image: PlatformImage, for host: String, persist data: Data? = nil) {
        let key = host.lowercased()
        memory.setObject(image, forKey: key as NSString)
        images[key] = image
        if let data { writeDisk(data, for: key) }
    }

    /// Disk filename for a host. Hosts are `[a-z0-9.-]` by resolver
    /// contract; anything else is sanitized so the cache can never escape
    /// its directory.
    public static func fileName(for host: String) -> String {
        let lower = host.lowercased()
        let safe = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_" }
        return String(safe) + ".ico"
    }

    // MARK: - Disk

    private var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("favicons", isDirectory: true)
    }

    private func readDisk(for key: String) -> PlatformImage? {
        guard let directory,
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(Self.fileName(for: key)).path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < freshness,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(for: key))),
              let image = PlatformImage(data: data)
        else { return nil }
        return image
    }

    private func writeDisk(_ data: Data, for key: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName(for: key)), options: .atomic)
    }
}

/// Cached favicon with synchronous family-symbol fallback. Shows the cached
/// image when held, the fallback while loading or on any failure — rows
/// never flash empty and never show a spinner farm.
struct CachedFaviconImage: View {
    @ObservedObject private var store = FaviconStore.shared
    let host: String
    let fallback: String

    var body: some View {
        Group {
            if let image = store.cachedImage(for: host) {
                platformImage(image)
            } else {
                Image(systemName: fallback)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: host.lowercased()) {
            await store.load(host: host)
        }
    }

    @ViewBuilder
    private func platformImage(_ image: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        #endif
    }
}
