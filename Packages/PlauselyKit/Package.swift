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
    targets: [
        .target(name: "AnalyticsCore"),
        .target(
            name: "PlausibleClient",
            dependencies: ["AnalyticsCore"]
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
