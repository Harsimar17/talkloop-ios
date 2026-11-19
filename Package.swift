// swift-tools-version: 6.0
// For building with xtool (https://github.com/xtool-org/xtool) on Linux or Windows (WSL):
// `xtool dev` in this folder builds the app from this package and installs it on a connected iPhone.
// (On a Mac, project.yml + XcodeGen makes an Xcode project from the same sources.)
import PackageDescription

let package = Package(
    name: "Talkloop",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "Talkloop", targets: ["Talkloop"]),
    ],
    targets: [
        .target(
            name: "Talkloop",
            path: "Sources/Talkloop",
            swiftSettings: [
                // The code is written for Swift 5's concurrency checking, as in the Xcode project.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
