// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacAmp",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "MacAmp", targets: ["MacAmp"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacAmp",
            dependencies: [
                "AudioWorkgroupShim",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "MacAmpApp",
            exclude: [
                "Info.plist",
                "MacAmp.entitlements",
                "MacAmpApp-Bridging-Header.h",
                "Audio/ObjCBridge",
            ],
            resources: [
                .process("Skins"),
                .process("Assets.xcassets")
            ]
        ),
        // SwiftPM targets can't mix languages; Xcode uses the bridging header.
        .target(
            name: "AudioWorkgroupShim",
            path: "MacAmpApp/Audio/ObjCBridge",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "MacAmpTests",
            dependencies: [
                "MacAmp",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Tests/MacAmpTests",
            resources: [
                .process("Fixtures"),
            ]
        )
    ]
)
