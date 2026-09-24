// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeaCoffee",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SeaCoffee", targets: ["SeaCoffee"])],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(name: "SeaCoffee", dependencies: ["IslandCore"]),
        .executableTarget(name: "IslandChecks", dependencies: ["IslandCore"], path: "Tests/IslandCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
