// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tidy-downloads",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "tidy-downloads",
            dependencies: [.product(name: "Rainbow", package: "Rainbow")]
        )
    ]
)
