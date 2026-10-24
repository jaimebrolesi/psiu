// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Psiu",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that doesn't draw: the files in ~/.psiu, hooks, status line, installer and the rules behind the robot.
        .target(name: "PsiuCore"),
        // The app on screen: notch panels, views and the robot.
        .executableTarget(name: "Psiu", dependencies: ["PsiuCore"]),
        .testTarget(name: "PsiuCoreTests", dependencies: ["PsiuCore"]),
        // The robot drawn now against frames saved from an earlier version.
        .testTarget(name: "PsiuTests", dependencies: ["Psiu"], resources: [.copy("Golden")]),
    ]
)
