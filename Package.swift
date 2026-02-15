// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "localvoxtral",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "localvoxtral", targets: ["localvoxtral"]),
    ],
    targets: [
        .executableTarget(
            name: "localvoxtral"
        ),
        .testTarget(
            name: "localvoxtralTests",
            dependencies: ["localvoxtral"]
        ),
    ]
)
