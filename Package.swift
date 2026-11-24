// swift-tools-version:6.0
// Lets Xcode or `swift build` open the project. build.sh is what produces the .app bundle.
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
