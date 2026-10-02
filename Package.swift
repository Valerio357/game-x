// swift-tools-version:5.9
import PackageDescription

// Nota: niente `testTarget` con XCTest/Swift Testing perché su questa macchina
// xcode-select punta al CommandLineTools, che non espone quei moduli, e la
// licenza Xcode non è accettata. I self-test vivono in `gx-selftest`.
let package = Package(
    name: "game-x",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GameXCore", targets: ["GameXCore"]),
        .executable(name: "gx", targets: ["gx"]),
        .executable(name: "gx-selftest", targets: ["gx-selftest"]),
        .executable(name: "GameX", targets: ["GameX"]),
    ],
    targets: [
        .target(
            name: "GameXCore",
            path: "Sources/GameXCore",
            resources: [
                .copy("Resources/steamwebhelper_shim.c"),
                .copy("Resources/build-runtime-gptk.sh"),
            ]
        ),
        .executableTarget(
            name: "gx",
            dependencies: ["GameXCore"],
            path: "Sources/gx"
        ),
        .executableTarget(
            name: "gx-selftest",
            dependencies: ["GameXCore"],
            path: "Sources/gx-selftest"
        ),
        .executableTarget(
            name: "GameX",
            dependencies: ["GameXCore"],
            path: "Sources/GameX"
        ),
    ]
)
