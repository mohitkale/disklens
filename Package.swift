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
        // Reads the SSD's NVMe health log through IOKit (macOS only; empty elsewhere).
        .target(name: "DiskLensHealth", linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS])),
                                                         .linkedFramework("CoreFoundation")]),
        .target(name: "DiskLensCore", dependencies: [.target(name: "DiskLensHealth", condition: .when(platforms: [.macOS]))]),
        .executableTarget(name: "DiskLensApp", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
