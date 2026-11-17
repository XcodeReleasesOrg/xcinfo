// swift-tools-version:6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "xcinfo",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "xcinfo",
            targets: ["xcinfo"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/onevcat/Rainbow", from: "4.2.2"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.2"),
        .package(url: "https://github.com/saagarjha/unxip", from: "3.3.0"),
        // XCModel was moved out of this repository after this revision, so it stays pinned here.
        .package(url: "https://github.com/xcodereleases/data.git", revision: "500ee363f568086454a881a1343713704b125855"),
    ],
    targets: [
        .target(
            name: "XCIFoundation",
            dependencies: ["Rainbow"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "XCUnxip",
            dependencies: []
        ),
        .target(
            name: "XCInfoTUI",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                "XCIFoundation",
                "xcinfoCore",
                .product(name: "XCModel", package: "data"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "xcinfo",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                "XCInfoTUI",
                "xcinfoCore",
                "XCIFoundation",
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [
                LinkerSetting.linkedFramework("PackageKit"),
                LinkerSetting.unsafeFlags(["-F/System/Library/PrivateFrameworks/"]),
            ]
        ),
        .target(
            name: "xcinfoCore",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "OlympUs",
                "XCIFoundation",
                "XCUnxip",
                .product(name: "libunxip", package: "unxip"),
                .product(name: "XCModel", package: "data"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "xcinfoCoreTests",
            dependencies: [
                "xcinfo",
                "xcinfoCore",
                "XCInfoTUI",
                "OlympUs",
                "XCIFoundation",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "XCModel", package: "data"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [
                LinkerSetting.linkedFramework("PackageKit"),
                LinkerSetting.unsafeFlags(["-F/System/Library/PrivateFrameworks/"]),
            ]
        ),
        .target(
            name: "OlympUs",
            dependencies: ["XCIFoundation"],
            swiftSettings: swiftSettings
        ),
    ]
)
