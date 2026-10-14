// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyLibrary",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MyLibrarySDKCore", targets: ["MyLibrarySDKCoreBinary"]),
        .library(
            name: "MyLibrarySDKFeature",
            targets: ["MyLibrarySDKFeatureBinary", "MyLibrarySDKCoreBinary"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "MyLibrarySDKCoreBinary",
            path: "Binaries/MyLibrarySDKCoreBinary.xcframework"
        ),
        .binaryTarget(
            name: "MyLibrarySDKFeatureBinary",
            path: "Binaries/MyLibrarySDKFeatureBinary.xcframework"
        ),
    ]
)
