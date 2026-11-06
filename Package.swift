// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidFileTransfer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AndroidFileTransferKit", targets: ["AndroidFileTransferKit"]),
        .executable(name: "AndroidFileTransferApp", targets: ["AndroidFileTransferApp"]),
    ],
    targets: [
        .target(
            name: "AndroidFileTransferKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "AndroidFileTransferApp",
            dependencies: ["AndroidFileTransferKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        .testTarget(
            name: "AndroidFileTransferKitTests",
            dependencies: ["AndroidFileTransferKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
