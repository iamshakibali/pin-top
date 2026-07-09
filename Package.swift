// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowPin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "WindowPin",
            targets: ["WindowPin"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "WindowPin",
            path: "Sources/WindowPin"
        ),
    ]
)
