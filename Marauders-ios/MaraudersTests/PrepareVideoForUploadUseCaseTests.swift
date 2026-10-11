//
//  PrepareVideoForUploadUseCaseTests.swift
//  MaraudersTests
//

import Foundation
import Testing
@testable import Marauders

@MainActor
struct PrepareVideoForUploadUseCaseTests {
    @Test func executeReturnsExporterOutputAndForwardsSource() async throws {
        let source = try TestFixtureFiles.temporaryVideoFile(byteCount: 4, extension: "mov")
        let mp4 = try TestFixtureFiles.temporaryVideoFile(byteCount: 8)
        let exporter = RecordingVideoExporter(result: .success(mp4))
        let useCase = PrepareVideoForUploadUseCase(exporter: exporter)

        let result = try await useCase.execute(sourceURL: source)

        #expect(result == mp4)
        #expect(exporter.lastSourceURL == source)
    }

    @Test func executePropagatesExporterError() async {
        let exporter = StubVideoExporter(result: .failure(StubError.exportFailed))
        let useCase = PrepareVideoForUploadUseCase(exporter: exporter)

        await #expect(throws: StubError.exportFailed) {
            _ = try await useCase.execute(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"))
        }
    }
}
