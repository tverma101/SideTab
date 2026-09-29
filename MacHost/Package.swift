// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sourceDirectory = "\(packageRoot)/Sources"
let moduleMapPath = "\(sourceDirectory)/module.modulemap"

let package = Package(
    name: "SideScreen",
    platforms: [
        // Floor is ScreenCaptureKit basics (12.3) + OSAllocatedUnfairLock /
        // SCStreamConfiguration.capturesAudio (13.0). CGVirtualDisplay is a
        // private API present well before 13 — it does NOT require 14.
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SideScreen",
            targets: ["SideScreen"])
    ],
    targets: [
        .executableTarget(
            name: "SideScreen",
            dependencies: [],
            path: "Sources",
            cSettings: [
                .unsafeFlags(["-I", sourceDirectory])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=\(moduleMapPath)"])
            ]),
        .testTarget(
            name: "SideScreenTests",
            dependencies: ["SideScreen"],
            path: "Tests/SideScreenTests",
            cSettings: [
                .unsafeFlags(["-I", sourceDirectory])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=\(moduleMapPath)"])
            ]
        )
    ]
)
