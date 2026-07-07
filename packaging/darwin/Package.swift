// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "nix-install",
    platforms: [
        // Matches the project deployment target (DESIGN.md §4).
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "nix-install",
            path: "Sources/nix-install"
        ),
        .testTarget(
            name: "nix-installTests",
            dependencies: ["nix-install"],
            path: "Tests/nix-installTests"
        ),
    ]
)
