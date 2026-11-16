// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Knob",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Knob",
            path: "Sources/Knob",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
