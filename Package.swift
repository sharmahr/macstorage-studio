// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacStorageStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacStorageCore", targets: ["MacStorageCore"]),
        .library(name: "MetadataStore", targets: ["MetadataStore"]),
        .library(name: "ScannerEngine", targets: ["ScannerEngine"]),
        .library(name: "ScannerClient", targets: ["ScannerClient"]),
        .library(name: "Classifier", targets: ["Classifier"]),
        .library(name: "Recommendations", targets: ["Recommendations"]),
        .library(name: "CleanupEngine", targets: ["CleanupEngine"]),
        .library(name: "Analysis", targets: ["Analysis"]),
        .executable(name: "ScannerWorker", targets: ["ScannerWorker"]),
        .executable(name: "MacStorageStudio", targets: ["MacStorageStudioApp"]),
    ],
    targets: [
        .target(
            name: "MacStorageCore",
            path: "Packages/MacStorageCore/Sources/MacStorageCore"
        ),
        .target(
            name: "MetadataStore",
            dependencies: ["MacStorageCore"],
            path: "Packages/MetadataStore/Sources/MetadataStore"
        ),
        .target(
            name: "ScannerEngine",
            dependencies: ["MacStorageCore"],
            path: "Packages/ScannerEngine/Sources/ScannerEngine"
        ),
        .target(
            name: "ScannerClient",
            dependencies: ["MacStorageCore", "ScannerEngine"],
            path: "Packages/ScannerClient/Sources/ScannerClient"
        ),
        .target(
            name: "Classifier",
            dependencies: ["MacStorageCore"],
            path: "Packages/Classifier/Sources/Classifier"
        ),
        .target(
            name: "Recommendations",
            dependencies: ["MacStorageCore", "Classifier"],
            path: "Packages/Recommendations/Sources/Recommendations"
        ),
        .target(
            name: "CleanupEngine",
            dependencies: ["MacStorageCore"],
            path: "Packages/CleanupEngine/Sources/CleanupEngine"
        ),
        .target(
            name: "Analysis",
            dependencies: ["MacStorageCore"],
            path: "Packages/Analysis/Sources/Analysis"
        ),
        .executableTarget(
            name: "ScannerWorker",
            dependencies: ["MacStorageCore", "ScannerEngine"],
            path: "Packages/ScannerWorker/Sources/ScannerWorker"
        ),
        .executableTarget(
            name: "MacStorageStudioApp",
            dependencies: [
                "MacStorageCore",
                "MetadataStore",
                "ScannerClient",
                "Classifier",
                "Recommendations",
                "CleanupEngine",
                "Analysis",
            ],
            path: "App/MacStorageStudio",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MacStorageTests",
            dependencies: [
                "MacStorageCore",
                "MetadataStore",
                "ScannerEngine",
                "ScannerClient",
                "Classifier",
                "Recommendations",
                "CleanupEngine",
                "Analysis",
            ],
            path: "Tests/MacStorageTests"
        ),
    ]
)
