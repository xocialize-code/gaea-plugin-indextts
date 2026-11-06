// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-indextts: bilibili's IndexTTS 2.5 (bilibili Model Use Licence weights; the MLX port, mlx-indextts2-swift, is
// Apache-2.0) as a Gaea plugin on MES Audio 0.1. One worker executable built on GaeaPluginKit over mlx-indextts2-swift,
// packaged as a signed .gaeaplugin by scripts/build-plugin.sh.
//
// indextts-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, requests and seeding, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-indextts",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.10.0"),
        .package(url: "https://github.com/xocialize/mlx-indextts2-swift.git", from: "0.6.0"), // the caller-keyed voice cache MES §13 allows (AB-A-0251)
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.74.1"),
        // MLX's random state, which the GPT samples from: a seeded run seeds it first. The fleet's mlx-swift fork, as
        // mlx-engine-swift 0.74.1 takes it: 0.32.4 is upstream 0.32.3 plus the _updateInternal leak fix
        // (ml-explore/mlx-swift#501; AB-D-0208). A root line naming ml-explore's URL would win and drop the fix.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.32.4"),
    ],
    targets: [
        .target(
            name: "IndexTTSPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXIndexTTS2TTS", package: "mlx-indextts2-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-indextts-worker",
            dependencies: [
                "IndexTTSPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "indextts-inproc",
            dependencies: [
                "IndexTTSPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXIndexTTS2TTS", package: "mlx-indextts2-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "IndexTTSPluginTests", dependencies: ["IndexTTSPlugin"]),
    ]
)
