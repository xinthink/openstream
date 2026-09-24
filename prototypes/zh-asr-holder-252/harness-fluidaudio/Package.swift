// swift-tools-version:6.0
import PackageDescription

// Spike-only harness for ADR-0004 gate #1, candidate A0:
// SenseVoiceSmall (CoreML / ANE) through FluidAudio - already the dependency the
// product's transcription-helper links. Throwaway: nothing here is OpenStream
// product code, and nothing here ships.
//
// The dependency is a *path* into the pinned checkout that the product build
// already resolved, so the spike needs no second network fetch for the library:
//   native/transcription-helper/.build/checkouts/FluidAudio  (0.15.6)
// A portable re-run should replace it with the pinned URL:
//   .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
let package = Package(
    name: "zh-smoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../native/transcription-helper/.build/checkouts/FluidAudio")
    ],
    targets: [
        .executableTarget(
            name: "zh-smoke",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/zh-smoke"
        )
    ]
)
