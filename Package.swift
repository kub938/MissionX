// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MissionX",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MissionX", targets: ["MissionX"])],
    targets: [.executableTarget(name: "MissionX", path: "Sources/MissionX")]
)
