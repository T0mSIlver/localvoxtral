// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "supervoxtral",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "SuperVoxtral", targets: ["supervoxtral"]),
    ],
    targets: [
        .executableTarget(
            name: "supervoxtral"
        ),
    ]
)
