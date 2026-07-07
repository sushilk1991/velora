// swift-tools-version:6.1
// Velora — local-first dictation for macOS.
// Built with SwiftPM only (CommandLineTools, no Xcode). The Info.plist is
// embedded into the bare binary via -sectcreate (spike-proven pattern) so a
// `swift build` binary still reports com.velora.app metadata; the hand-rolled
// .app bundle (scripts/make-app.sh) carries the authoritative Contents/Info.plist.
import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Velora",
            path: "Sources/Velora",
            swiftSettings: [
                // Swift 5 language mode: AVAudioEngine tap closures and the
                // CGEventTap C callback fight Swift 6 strict concurrency
                // (see spikes/menubar/FINDINGS.md).
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        )
    ]
)
