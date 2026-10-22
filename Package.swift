// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacFanControl",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCKit"),
        .executableTarget(name: "fanctl", dependencies: ["SMCKit"]),
        .executableTarget(name: "FanBar", dependencies: ["SMCKit"]),
    ]
)
