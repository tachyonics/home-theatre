// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeTheatre",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HomeTheatreCore", targets: ["HomeTheatreCore"]),
        .executable(name: "AdminUI", targets: ["AdminUI"]),
    ],
    targets: [
        .target(name: "HomeTheatreCore"),
        .executableTarget(name: "AdminUI", dependencies: ["HomeTheatreCore"]),
        .testTarget(name: "HomeTheatreCoreTests", dependencies: ["HomeTheatreCore"]),
    ]
)
