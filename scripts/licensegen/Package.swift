// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "licensegen",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "licensegen", path: "Sources/licensegen")]
)
