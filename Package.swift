// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "chargnr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChargnrCore", targets: ["ChargnrCore"]),
        .executable(name: "chargnr", targets: ["chargnr"]),
        .executable(name: "chargnr-helper", targets: ["chargnr-helper"]),
    ],
    targets: [
        .target(name: "ChargnrCore"),
        .executableTarget(name: "chargnr", dependencies: ["ChargnrCore"]),
        .executableTarget(name: "chargnr-helper", dependencies: ["ChargnrCore"]),
        .testTarget(name: "ChargnrCoreTests", dependencies: ["ChargnrCore"]),
    ]
)
