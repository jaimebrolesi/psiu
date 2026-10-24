// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Psiu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Psiu", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
