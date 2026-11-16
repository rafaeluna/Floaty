// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Floaty",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Floaty",
            path: "Sources/Floaty",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
