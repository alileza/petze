// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "batmon",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "batmon", path: "Sources/batmon")
    ]
)
