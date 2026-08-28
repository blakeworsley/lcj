// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clodex-menubar",
    platforms: [.macOS(.v13)],   // v13 floor: SMAppService for Launch at Login
    targets: [
        .target(name: "ClodexCore"),
        .executableTarget(name: "ClodexMenubar", dependencies: ["ClodexCore"]),
        .executableTarget(name: "ClodexTests", dependencies: ["ClodexCore"]),
    ]
)
