// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SideScreenQualityLab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sidescreen-quality-lab", targets: ["SideScreenQualityLab"]),
    ],
    targets: [
        .executableTarget(name: "SideScreenQualityLab", path: "Sources"),
    ]
)
