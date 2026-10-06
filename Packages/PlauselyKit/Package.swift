// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlauselyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnalyticsCore", targets: ["AnalyticsCore"]),
        .library(name: "PlausibleClient", targets: ["PlausibleClient"]),
        .library(name: "DashboardUI", targets: ["DashboardUI"]),
    ],
    dependencies: [
        // HTML parsing for dashboard bootstrap/discovery (phase-00 anticipated
        // dependency). SwiftSoup is MIT-licensed; full notice in
        // THIRD_PARTY_NOTICES at release (phase 10).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "AnalyticsCore"),
        .target(
            name: "PlausibleClient",
            dependencies: ["AnalyticsCore", .product(name: "SwiftSoup", package: "SwiftSoup")]
        ),
        .target(
            name: "DashboardUI",
            dependencies: ["AnalyticsCore"]
        ),
        .testTarget(
            name: "AnalyticsCoreTests",
            dependencies: ["AnalyticsCore"]
        ),
        .testTarget(
            name: "PlausibleClientTests",
            dependencies: ["PlausibleClient"]
        ),
    ]
)
