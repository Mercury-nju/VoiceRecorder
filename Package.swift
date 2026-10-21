// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceRecorder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceRecorder", targets: ["VoiceRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "VoiceRecorderTests",
            dependencies: ["VoiceRecorder"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
