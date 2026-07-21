// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PinTop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PinTop",
            targets: ["PinTop"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "PinTop",
            path: "Sources/PinTop",
            resources: [.copy("Resources/PinTop.icns")]
        ),
    ]
)
