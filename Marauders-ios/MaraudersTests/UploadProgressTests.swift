//
//  UploadProgressTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct UploadProgressDelegateTests {
    /// A task that is never resumed: the delegate only needs one to name in its callback.
    private static let task = URLSession.shared.dataTask(with: URL(string: "https://api.example.test/clip")!)

    @Test func itReportsTheFractionSentAndEndsAtOne() {
        let log = UploadProgressLog()
        let delegate = UploadProgressDelegate(handler: log.handler)

        Self.send(250, of: 1000, to: delegate)
        #expect(log.values == [0.25])

        Self.send(1000, of: 1000, to: delegate)
        #expect(log.values == [0.25, 1.0])
    }

    @Test func itReportsOnlyWhenTheWholePercentChanges() {
        let log = UploadProgressLog()
        let delegate = UploadProgressDelegate(handler: log.handler)

        for sent in 1...1000 {
            Self.send(Int64(sent), of: 1000, to: delegate)
        }

        let values = log.values
        #expect(values.count <= 101)
        #expect(values == values.sorted())
        #expect(values.last == 1.0)
        #expect(values.allSatisfy { (0.0...1.0).contains($0) })
    }

    @Test func itIgnoresAnUnknownOrZeroTotal() {
        let log = UploadProgressLog()
        let delegate = UploadProgressDelegate(handler: log.handler)

        Self.send(100, of: -1, to: delegate)  // NSURLSessionTransferSizeUnknown
        Self.send(100, of: 0, to: delegate)

        #expect(log.values.isEmpty)
    }

    @Test func itNeverReportsMoreThanOne() {
        let log = UploadProgressLog()
        let delegate = UploadProgressDelegate(handler: log.handler)

        Self.send(1200, of: 1000, to: delegate)

        #expect(log.values == [1.0])
    }

    @Test func itReportsAgainWhenTheBodyIsSentFromTheStart() {
        let log = UploadProgressLog()
        let delegate = UploadProgressDelegate(handler: log.handler)

        // A replay after a rejected session sends the body again: the count restarts, so must the report.
        Self.send(900, of: 1000, to: delegate)
        Self.send(100, of: 1000, to: delegate)

        #expect(log.values == [0.9, 0.1])
    }

    private static func send(_ sent: Int64, of total: Int64, to delegate: UploadProgressDelegate) {
        delegate.urlSession(
            .shared, task: task, didSendBodyData: 0, totalBytesSent: sent, totalBytesExpectedToSend: total)
    }
}

@MainActor
struct HTTPClientProgressDefaultTests {
    @Test func aClientThatOnlyKnowsTheOldUploadStillUploadsAndNeverReports() async throws {
        let base = ScriptedHTTP(status: 201)
        let log = UploadProgressLog()
        var request = URLRequest(url: URL(string: "https://api.example.test/v1/videos")!)
        request.httpMethod = "POST"

        let response = try await base.upload(
            request, multipart: [.field(name: "a", value: "b")], progress: log.handler)

        #expect(response.statusCode == 201)
        #expect(base.requests.count == 1)
        #expect(log.values.isEmpty)
    }
}
