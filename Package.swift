// swift-tools-version:5.10
import PackageDescription

// DiskLensCore holds the models, history store and version logic (shared, so an
// iOS companion can reuse it later) plus the macOS-only scanner and cleanup rules.
let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
        .executable(name: "DiskLens", targets: ["DiskLensApp"]),
    ],
    targets: [
        .target(name: "DiskLensCore"),
        .executableTarget(name: "DiskLensApp", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
