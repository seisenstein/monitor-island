// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MonitorIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CIOReport",
            path: "Sources/CIOReport"
        ),
        .executableTarget(
            name: "MonitorIsland",
            dependencies: ["CIOReport"],
            path: "Sources/MonitorIsland",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                // IOReport and IOHIDEventSystemClient private symbols have no .tbd stub;
                // resolve them at runtime via dynamic_lookup (SiliconScope pattern).
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])
            ]
        )
    ]
)
