// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shipyard",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Shipyard", path: "Sources")]
)
