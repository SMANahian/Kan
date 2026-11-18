// swift-tools-version:6.2
//
// Kan (কান, "ear") — a menu-bar app that detects calls, records both sides locally and
// transcribes them (Bangla + English) with speaker attribution.
//
// Build with an explicit product, e.g. `swift build -c release --product KanApp`.
// A plain `swift build` also compiles FluidAudio's own CLI target, which fails when only the
// "Diarizer" trait is enabled.
//
// The whisper.cpp static libraries in Vendor/whisper/lib are produced by scripts/bootstrap-whisper.sh.

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperLibDir = packageRoot + "/Vendor/whisper/lib"

// Our own targets use the Swift 5 language mode: Core Audio real-time callbacks and C interop
// are much less noisy there. FluidAudio still compiles in its own mode.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Kan",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KanApp", targets: ["KanApp"]),
        .executable(name: "kan", targets: ["kan"]),
        .executable(name: "kan-probe", targets: ["kan-probe"]),
        .executable(name: "kan-selftest-core", targets: ["kan-selftest-core"]),
        .executable(name: "kan-selftest-audio", targets: ["kan-selftest-audio"]),
        .executable(name: "kan-selftest-transcribe", targets: ["kan-selftest-transcribe"]),
        .executable(name: "kan-selftest-agent", targets: ["kan-selftest-agent"]),
        .executable(name: "kan-selftest-ai", targets: ["kan-selftest-ai"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        // C module exposing whisper.h (+ the ggml headers it includes) to Swift.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L" + whisperLibDir]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // Shared contracts (models, settings, paths, protocols) + storage, search, export,
        // processing queue and voiceprints. Foundation only.
        .target(name: "KanCore", path: "Sources/KanCore", swiftSettings: swift5),

        // Minimal test harness (XCTest / Swift Testing don't run under Command Line Tools).
        .target(name: "KanTestKit", path: "Sources/KanTestKit", swiftSettings: swift5),

        // Core Audio capture: process taps, mic, WAV writing, permissions, echo gate, archiving.
        .target(name: "KanAudio", dependencies: ["KanCore"], path: "Sources/KanAudio", swiftSettings: swift5),

        // Call detection: audio-client monitor, owner mapping, state machine, browser meeting probe.
        .target(name: "KanDetect", dependencies: ["KanCore", "KanAudio"], path: "Sources/KanDetect", swiftSettings: swift5),

        // Transcription: whisper.cpp engine, VAD, language routing, FluidAudio diarization, models.
        .target(
            name: "KanTranscribe",
            dependencies: ["KanCore", "CWhisper", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/KanTranscribe",
            swiftSettings: swift5
        ),

        // AI-agent surface: MCP server (JSON-RPC 2.0 over stdio) and the CLI commands.
        .target(name: "KanAgent", dependencies: ["KanCore"], path: "Sources/KanAgent", swiftSettings: swift5),

        // OpenAI title ideas and summaries (opt-in): Responses API client, prompts, the Keychain key store.
        .target(name: "KanAI", dependencies: ["KanCore"], path: "Sources/KanAI", swiftSettings: swift5),

        // The menu-bar app (bundled as Kan.app with CFBundleExecutable KanApp — the app binary
        // can't be called "Kan" because the CLI is "kan" and APFS is case-insensitive).
        .executableTarget(
            name: "KanApp",
            // Concrete services are wired in Sources/KanApp/Services/LiveServices.swift.
            dependencies: ["KanCore", "KanAudio", "KanDetect", "KanTranscribe", "KanAgent", "KanAI"],
            path: "Sources/KanApp",
            swiftSettings: swift5
        ),

        // Command-line tool + MCP server for AI agents.
        .executableTarget(name: "kan", dependencies: ["KanCore", "KanAgent", "KanTranscribe"], path: "Sources/kan", swiftSettings: swift5),

        // Read-only diagnostics (audio clients, owner mapping, permissions, live watch).
        .executableTarget(name: "kan-probe", dependencies: ["KanCore", "KanAudio", "KanDetect"], path: "Sources/kan-probe", swiftSettings: swift5),

        // Self-test executables, one per module (run them with `make test`).
        .executableTarget(name: "kan-selftest-core", dependencies: ["KanCore", "KanTestKit"], path: "Sources/kan-selftest-core", swiftSettings: swift5),
        .executableTarget(name: "kan-selftest-audio", dependencies: ["KanCore", "KanAudio", "KanDetect", "KanTestKit"], path: "Sources/kan-selftest-audio", swiftSettings: swift5),
        .executableTarget(name: "kan-selftest-transcribe", dependencies: ["KanCore", "KanTranscribe", "KanTestKit"], path: "Sources/kan-selftest-transcribe", swiftSettings: swift5),
        .executableTarget(name: "kan-selftest-agent", dependencies: ["KanCore", "KanAgent", "KanTestKit"], path: "Sources/kan-selftest-agent", swiftSettings: swift5),
        .executableTarget(name: "kan-selftest-ai", dependencies: ["KanCore", "KanAI", "KanTestKit"], path: "Sources/kan-selftest-ai", swiftSettings: swift5),
    ]
)
