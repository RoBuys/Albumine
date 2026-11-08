// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Albumine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Albumine", path: "Sources/Albumine")
    ]
)
