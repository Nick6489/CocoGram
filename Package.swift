// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CocoGram",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CocoGram", targets: ["CocoGram"])
    ],
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibKit", exact: "1.5.2-tdlib-1.8.64-e0943d06"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework", exact: "0.1.3"),
        .package(url: "https://github.com/sbooth/opus-binary-xcframework", exact: "0.3.0")
    ],
    targets: [
        .executableTarget(
            name: "CocoGram",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                .product(name: "opus", package: "opus-binary-xcframework"),
                "OpusShim"
            ],
            // Info.plist is consumed by the linker (below), not bundled as a resource.
            exclude: ["Info.plist"],
            // Embed Info.plist into the binary's __TEXT,__info_plist section so the
            // un-bundled `swift run` build carries NSMicrophoneUsageDescription — without
            // it, macOS TCC never shows the microphone prompt during development. The
            // path is relative to the package root, where the linker is invoked.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CocoGram/Info.plist"
                ])
            ]
        ),
        .target(
            name: "OpusShim",
            dependencies: [
                .product(name: "opus", package: "opus-binary-xcframework")
            ],
            publicHeadersPath: "include"
        )
    ]
)
