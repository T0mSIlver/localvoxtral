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
    dependencies: [
        .package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "localvoxtral",
            dependencies: [
                .product(name: "ShortcutRecorder", package: "ShortcutRecorder"),
            ]
        ),
        .testTarget(
            name: "localvoxtralTests",
            dependencies: ["localvoxtral"]
        ),
    ]
)
