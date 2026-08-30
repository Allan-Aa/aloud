// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aloud",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Aloud",
            path: "Sources/Aloud",
            resources: [.process("Resources")],
            // 先用 v5 并发模式推进功能;等链路稳定再收紧到 Swift 6 严格并发。
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .testTarget(
            name: "AloudTests",
            dependencies: ["Aloud"],
            path: "Tests/AloudTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
