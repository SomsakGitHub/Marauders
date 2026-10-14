// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyLibrary",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "MyLibrarySDKCore", targets: ["MyLibrarySDKCore"]),
        .library(name: "MyLibrarySDKFeature", targets: ["MyLibrarySDKFeature"]),
    ],
    targets: [
        .target(
            name: "MyLibrarySDKCore",
            path: "MyLibrarySDKCore/Sources"
        ),
        .target(
            name: "MyLibrarySDKFeature",
            dependencies: ["MyLibrarySDKCore"],
            path: "MyLibrarySDKFeature/Sources"
        ),
        .testTarget(
            name: "MyLibrarySDKCoreTests",
            dependencies: ["MyLibrarySDKCore"],
            path: "MyLibrarySDKCore/Tests"
        ),
    ]
)
