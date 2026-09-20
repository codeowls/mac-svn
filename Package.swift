// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSVN",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacSVN", targets: ["MacSVN"]),
        .library(name: "SVNCore", targets: ["SVNCore"])
    ],
    targets: [
        .target(name: "SVNCore", resources: [.process("Resources")]),
        .executableTarget(name: "MacSVN", dependencies: ["SVNCore"]),
        .testTarget(name: "SVNCoreTests", dependencies: ["SVNCore"])
    ]
)
