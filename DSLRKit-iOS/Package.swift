// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DSLRKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "DSLRKit", targets: ["DSLRKit"])],
    targets: [
        .target(name: "DSLRKit"),
        .testTarget(name: "DSLRKitTests", dependencies: ["DSLRKit"])
    ]
)
