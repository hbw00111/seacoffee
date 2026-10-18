// swift-tools-version: 6.2
import PackageDescription
import Foundation

// This template is staged by scripts/build-droplet.sh with the shared sources.
let sdk = ProcessInfo.processInfo.environment["SEACOFFEE_DROPPYKIT_PATH"]!
let package = Package(
    name: "SeaCoffeeDroplet",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SeaCoffeeDroplet", type: .dynamic, targets: ["SeaCoffeeDroplet"])],
    dependencies: [.package(name: "DroppyKit", path: sdk)],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "SeaCoffeeDroplet", dependencies: ["IslandCore", .product(name: "DroppyKit", package: "DroppyKit")],
                swiftSettings: [.define("SEACOFFEE_DROPPY"), .swiftLanguageMode(.v5)]),
        .executableTarget(name: "SeaCoffeeHarness", dependencies: ["SeaCoffeeDroplet", .product(name: "DroppyKitHarness", package: "DroppyKit")],
                path: "Harness", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SeaCoffeeDropletChecks", dependencies: ["SeaCoffeeDroplet", .product(name: "DroppyKitHarness", package: "DroppyKit")],
                    path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    swiftLanguageModes: [.v5]
)
