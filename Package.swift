// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-fm-audit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "apple-fm-audit", targets: ["AppleFMAudit"]),
        .library(name: "AppleFMAuditCore", targets: ["AppleFMAuditCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
    ],
    targets: [
        .target(
            name: "AppleFMAuditCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/AppleFMAuditCore"
        ),
        .executableTarget(
            name: "AppleFMAudit",
            dependencies: [
                "AppleFMAuditCore",
            ],
            path: "Sources/AppleFMAudit"
        ),
        .testTarget(
            name: "AppleFMAuditTests",
            dependencies: [
                "AppleFMAuditCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/AppleFMAuditTests"
        ),
    ]
)
