// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HostDock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HostDock", targets: ["HostDock"]),
        .executable(name: "HostDockCLI", targets: ["HostDockCLI"]),
        .executable(name: "HostDockCheck", targets: ["HostDockCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.1"),
    ],
    targets: [
        .target(name: "HostDockCore", dependencies: ["Citadel"]),
        .executableTarget(name: "HostDock", dependencies: ["HostDockCore", "SwiftTerm"]),
        .executableTarget(name: "HostDockCLI", dependencies: ["HostDockCore"]),
        .executableTarget(name: "HostDockCheck", dependencies: ["HostDockCore"]),
        .testTarget(name: "HostDockCoreTests", dependencies: ["HostDockCore"]),
        .testTarget(name: "HostDockAppTests", dependencies: ["HostDock", "HostDockCore"]),
    ],
    swiftLanguageModes: [.v5]
)
