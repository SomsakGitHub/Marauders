//
//  PrivacyManifestTests.swift
//  MaraudersTests
//

import Foundation
import Testing

/// The privacy manifest as it ships. The unit tests are hosted in the app, so `Bundle.main` is the app bundle.
struct PrivacyManifestTests {
    @Test func theManifestSaysWhyTheAppChecksFreeSpace() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])

        func reasons(of category: String) -> [String] {
            entries
                .filter { $0["NSPrivacyAccessedAPIType"] as? String == category }
                .flatMap { $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [] }
        }

        // The upload reads the free space of the volume before it stages a clip: a required-reason API.
        #expect(reasons(of: "NSPrivacyAccessedAPICategoryDiskSpace").contains("E174.1"))
        // What the app declared before is still declared.
        #expect(reasons(of: "NSPrivacyAccessedAPICategorySystemBootTime").contains("35F9.1"))
        #expect(reasons(of: "NSPrivacyAccessedAPICategoryUserDefaults").contains("CA92.1"))
    }
}
