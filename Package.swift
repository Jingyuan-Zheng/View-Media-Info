// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ViewMediaInfo",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ViewMediaInfo", targets: ["ViewMediaInfo"])
    ],
    targets: [
        .executableTarget(
            name: "ViewMediaInfo",
            path: "Sources/ViewMediaInfo",
            swiftSettings: [.define("STANDALONE_MEDIA_INFO")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
