// swift-tools-version:6.0
// build.sh builds this and wraps the executable in an .app bundle.
import PackageDescription

let package = Package(
    name: "ReviewDesk",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ReviewDesk",
            path: "Sources/ReviewDesk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
