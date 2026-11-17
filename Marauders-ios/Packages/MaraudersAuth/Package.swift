// swift-tools-version: 6.2
import PackageDescription

/// The app target's Swift settings (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, approachable concurrency, member import
/// visibility), so code moved here keeps its meaning.
let appSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "MaraudersAuth",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "MaraudersAuth", targets: ["MaraudersAuth"])
    ],
    targets: [
        .target(name: "MaraudersAuth", swiftSettings: appSettings)
    ],
    swiftLanguageModes: [.v6]
)
