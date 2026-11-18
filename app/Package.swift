// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spatialize",
    platforms: [.macOS(.v26)],
    targets: [
        // libmysofa (BSD-3-Clause, vendor/libmysofa) for reading SOFA HRTF files, plus a small bridge
        .target(
            name: "CMySofa",
            path: "Sources/CMySofa",
            exclude: ["LICENSE.libmysofa"],
            cSettings: [
                .headerSearchPath("mysofa"),
                .headerSearchPath("mysofa/hrtf"),
                .headerSearchPath("mysofa/resampler"),
                .define("FLOATING_POINT"),
                .define("OUTSIDE_SPEEX"),
                .define("RANDOM_PREFIX", to: "mysofa"),
                .define("EXPORT", to: ""),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "Spatialize",
            dependencies: ["CMySofa"],
            path: "Sources/Spatialize",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
