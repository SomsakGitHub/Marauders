//
//  UploadRecordTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

struct UploadRecordTests {
    private static let clip = FeedVideo(
        id: UUID(uuidString: "5C1E6D7A-3B2F-4E8A-9D10-2A7B6C5D4E3F")!,
        streamURL: URL(string: "https://stream.example.com/clip.m3u8")!,
        latitude: 13.7563,
        longitude: 100.5018,
        country: "TH",
        authorName: "somsak",
        authorAvatarURL: URL(string: "https://img.example.com/somsak.jpg"),
        caption: "Sunset over Bangkok",
        audioAssessment: ClipAudioAssessment(
            content: .speech, speechConfidence: 0.8, musicConfidence: 0.1, signal: .detected,
            spokenLanguage: .init(status: "likely", code: "en", confidence: 0.9), sampledSeconds: 3),
        likeCount: 3,
        likedByViewer: true,
        commentCount: 2,
        postedByViewer: true,
        authorFollowedByViewer: false
    )

    /// Every failure with the text and the Try again answer the table of the plan gives it. The three that carry text
    /// show it as it is: the transport's own text, or the Worker's `error`, or `Upload failed (status N)`.
    private static let failures: [(failure: UploadFailure, message: String, canRetry: Bool)] = [
        (.rateLimited, "Too many uploads, try again in a minute", true),
        (.sessionEnded, "Your session ended. Sign in to try again.", true),
        (.unavailable, "The service is unavailable right now. Try again.", true),
        (.interrupted, "The upload was interrupted. Try again.", true),
        (.responseLost, "The clip may have been uploaded, but the answer was lost. Try again.", true),
        (.bodyMissing, "The clip is no longer on this iPhone. Choose the video again.", false),
        (.connection("The network connection was lost."), "The network connection was lost.", true),
        (.connection("The request timed out."), "The request timed out.", true),
        (.rejected("Unsupported video format"), "Unsupported video format", false),
        (.rejected("Upload failed (status 413)"), "Upload failed (status 413)", false),
        (.serverError("Storage is busy"), "Storage is busy", true),
        (.serverError("Upload failed (status 503)"), "Upload failed (status 503)", true),
    ]

    /// Every way a record can stand: each state once, `uploading` with both answers of `refreshedOnce`, and `failed`
    /// with every failure.
    private static var everyState: [UploadRecordState] {
        [
            .staged,
            .uploading(fraction: 0, refreshedOnce: false),
            .uploading(fraction: 0.42, refreshedOnce: true),
            .finished(clip),
        ] + failures.map { .failed($0.failure) }
    }

    private static func record(_ state: UploadRecordState) -> UploadRecord {
        let id = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
        return UploadRecord(
            version: UploadRecord.currentVersion,
            id: id,
            accountSubject: "001234.abcdef.5678",
            bodyFileName: "\(id.uuidString.lowercased()).multipart",
            boundary: "marauders.boundary.6B29FC40-CA47-1067-B31D-00DD010662DA",
            byteCount: 4_096,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: state
        )
    }

    @Test func aRecordRoundTripsThroughJsonInEveryState() throws {
        #expect(UploadRecord.currentVersion == 1)

        for state in Self.everyState {
            let record = Self.record(state)

            let decoded = try JSONDecoder().decode(UploadRecord.self, from: JSONEncoder().encode(record))

            #expect(decoded == record, "state \(state)")
        }
    }

    @Test func aRecordHoldsNothingButItsOwnFields() throws {
        let ownFields: Set<String> = [
            "version", "id", "accountSubject", "bodyFileName", "boundary", "byteCount", "createdAt", "state",
        ]

        for state in Self.everyState {
            let json = try JSONEncoder().encode(Self.record(state))
            let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])

            #expect(Set(object.keys) == ownFields, "state \(state)")
        }
    }

    @Test func aFractionOfOneIsFinishingNotUploading() {
        #expect(Self.record(.staged).snapshot == .uploading(fraction: 0))
        #expect(Self.record(.uploading(fraction: 0.42, refreshedOnce: false)).snapshot == .uploading(fraction: 0.42))
        // Just short of every byte is still uploading, and every byte sent, or more counted, is finishing.
        #expect(Self.record(.uploading(fraction: 0.999, refreshedOnce: false)).snapshot == .uploading(fraction: 0.999))
        #expect(Self.record(.uploading(fraction: 1.0, refreshedOnce: false)).snapshot == .finishing)
        #expect(Self.record(.uploading(fraction: 1.5, refreshedOnce: true)).snapshot == .finishing)
    }

    @Test func aFinishedOrFailedRecordHandsItsClipOrItsFailureToTheSnapshot() {
        #expect(Self.record(.finished(Self.clip)).snapshot == .finished(Self.clip))

        for row in Self.failures {
            #expect(
                Self.record(.failed(row.failure)).snapshot == .failed(message: row.message, canRetry: row.canRetry),
                "failure \(row.failure)")
        }
    }

    @Test func theFailureTextsAreExact() {
        for row in Self.failures {
            #expect(row.failure.message == row.message, "failure \(row.failure)")
        }
    }

    /// A fixed failure is stored as its case alone. Its sentence is made when it is shown, in the language the app has
    /// then, so a record written under one language never shows another one's text. (The three failures that carry a
    /// text keep the text they were made with.)
    @Test func fixedFailuresStoreNoSentence() throws {
        let fixed: [UploadFailure] = [
            .sessionEnded, .unavailable, .rateLimited, .interrupted, .responseLost, .bodyMissing,
        ]
        let stored = try #require(String(data: JSONEncoder().encode(fixed), encoding: .utf8))
        for failure in fixed {
            #expect(!stored.contains(failure.message), "failure \(failure)")
        }
    }

    @Test func onlyARejectedUploadAndAMissingBodyCannotBeRetried() {
        for row in Self.failures {
            switch row.failure {
            case .rejected, .bodyMissing:
                #expect(row.failure.canRetry == false, "failure \(row.failure)")
            case .sessionEnded, .unavailable, .connection, .rateLimited, .serverError, .interrupted, .responseLost:
                #expect(row.failure.canRetry == true, "failure \(row.failure)")
            }
        }
    }
}
