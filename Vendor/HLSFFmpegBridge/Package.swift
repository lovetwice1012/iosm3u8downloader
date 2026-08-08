// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HLSFFmpegBridge",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "HLSFFmpegBridge", targets: ["HLSFFmpegBridge"])
    ],
    targets: [
        .binaryTarget(
            name: "ffmpegkit",
            url: "https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.10.5-ios/bundle-base-ios-universal-small-lgpl.xcframework.zip",
            checksum: "34d13d53814e1bc9148354d62d122a058e1d07d8a81b3cba3e5b89edf645316c"
        ),
        .target(
            name: "HLSFFmpegBridge",
            dependencies: ["ffmpegkit"],
            publicHeadersPath: "include"
        )
    ]
)
