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
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
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
            dependencies: ["AndroidFileTransferKit", "Sparkle"],
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
            name: "AndroidFileTransferAppTests",
            dependencies: ["AndroidFileTransferApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
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
