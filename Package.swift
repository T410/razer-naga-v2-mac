// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Naga",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Naga", targets: ["Naga"]),
        .library(name: "NagaCore", targets: ["NagaCore"])
    ],
    targets: [
        .target(name: "NagaCore"),
        .executableTarget(name: "Naga", dependencies: ["NagaCore"],
                          linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "NagaCoreTests", dependencies: ["NagaCore"]),
        .testTarget(name: "NagaTests", dependencies: ["Naga"])
    ],
    swiftLanguageModes: [.v5]
)
