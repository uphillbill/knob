// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Knob",
    platforms: [.macOS("14.2")],
    targets: [
        // Acquire/release atomics for the EQ coefficient hand-off (Swift's Atomic needs macOS 15).
        .target(name: "KnobAtomics", path: "Sources/KnobAtomics"),
        // EQ math and the real-time filter bank. No Core Audio, so it can be checked on its own.
        .target(name: "KnobDSP", dependencies: ["KnobAtomics"], path: "Sources/KnobDSP"),
        .executableTarget(
            name: "Knob",
            dependencies: ["KnobDSP"],
            path: "Sources/Knob",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // DSP checks: `swift run EQCheck`. A plain executable because XCTest and Swift Testing
        // aren't available with the Command Line Tools alone.
        .executableTarget(name: "EQCheck", dependencies: ["KnobDSP"], path: "Sources/EQCheck"),
    ]
)
