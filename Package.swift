// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDetect",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacDetect", targets: ["MacDetectApp"])],
    targets: [
        .target(name: "MacDetectCore"),
        .executableTarget(name: "MacDetectApp", dependencies: ["MacDetectCore"]),
        .testTarget(name: "MacDetectCoreTests", dependencies: ["MacDetectCore"])
    ]
)
