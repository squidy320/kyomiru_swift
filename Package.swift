// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KyomiruSwift",
    platforms: [
        .iOS(.v16),
    ],
    targets: [
        .executableTarget(
            name: "KyomiruSwift",
            path: "Sources"
        ),
    ]
)
