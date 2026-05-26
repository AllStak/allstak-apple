// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AllStak",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "AllStak", targets: ["AllStak"]),
    ],
    targets: [
        .target(name: "AllStak"),
        .testTarget(name: "AllStakTests", dependencies: ["AllStak"]),
    ]
)
