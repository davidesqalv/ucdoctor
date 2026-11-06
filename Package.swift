// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ucdoctor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ucdoctor", path: "Sources/ucdoctor")
    ]
)
