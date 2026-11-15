// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "WoAManager",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "WoAManager", path: "Sources/WoAManager")]
)
