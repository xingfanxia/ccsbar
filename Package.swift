// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clauthbar",
    platforms: [.macOS(.v14)],
    targets: [
        // All app logic lives in the library so the test target can
        // `@testable import ClauthBarKit` and exercise the pure, regression-prone
        // functions (parseISO / resetHint / usageColor / fableWeek / decode) that
        // the executable alone couldn't expose to tests.
        .target(
            name: "ClauthBarKit",
            path: "Sources/ClauthBarKit",
            resources: [.copy("Fixtures/status.json")]
        ),
        // The thin executable: just `@main` → `runClauthBar()`.
        .executableTarget(
            name: "clauthbar",
            dependencies: ["ClauthBarKit"],
            path: "Sources/clauthbar"
        ),
        .testTarget(
            name: "ClauthBarKitTests",
            dependencies: ["ClauthBarKit"],
            path: "Tests/ClauthBarKitTests"
        ),
    ]
)
