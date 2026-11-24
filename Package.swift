// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-longcat-avatar: Meituan's LongCat-Video-Avatar 1.6 (MIT), an audio-driven talking avatar, as a Gaea
// plugin on MES Video 0.1's video.generate: a first frame (the person), a soundtrack (the speech) and a prompt make a
// clip in which the person speaks it. One worker executable built on GaeaPluginKit over longcat-avatar-mlx-swift,
// packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// longcat-avatar-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with
// the same dependency resolution, lane configuration and request, as the reference a run through Gaea is compared
// against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both; LONGCAT_AVATAR_SWIFT_PATH does the
// same for longcat-avatar-mlx-swift.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]
let longCatPath = Context.environment["LONGCAT_AVATAR_SWIFT_PATH"]

let package = Package(
    name: "gaea-plugin-longcat-avatar",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.16.0"),
        longCatPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize/longcat-avatar-mlx-swift.git", exact: "0.2.1"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.82.1"),
        // The fleet's mlx-swift fork at 0.33.1 (upstream 0.33.0 with the split-head attention routes off, AB-D-0264).
        // A root line naming ml-explore's URL is the same package identity and would bring the unpatched build back.
        .package(url: "https://github.com/xocialize/mlx-swift", exact: "0.33.1"),
    ],
    targets: [
        .target(
            name: "LongCatAvatarPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXLongCatAvatar", package: "longcat-avatar-mlx-swift"),
                .product(name: "LongCatVideoAvatar", package: "longcat-avatar-mlx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-longcat-avatar-worker",
            dependencies: [
                "LongCatAvatarPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "longcat-avatar-inproc",
            dependencies: [
                "LongCatAvatarPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXLongCatAvatar", package: "longcat-avatar-mlx-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LongCatAvatarPluginTests",
            dependencies: [
                "LongCatAvatarPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXLongCatAvatar", package: "longcat-avatar-mlx-swift"),
            ]
        ),
    ]
)
