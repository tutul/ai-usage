// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AIUsageKit", targets: ["UsageCore", "UsageProviders", "UsageStore", "UsageUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
    ],
    targets: [
        // 純 domain，零 I/O —— 專案唯一有微妙邏輯的地方，因此也是測試重心
        .target(name: "UsageCore"),
        .target(name: "UsageProviders", dependencies: ["UsageCore"]),
        .target(
            name: "UsageStore",
            dependencies: ["UsageCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/schema.sql")]
        ),
        .target(name: "UsageUI", dependencies: ["UsageCore", "UsageStore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageStoreTests", dependencies: ["UsageStore", "UsageCore"])
    ]
)
