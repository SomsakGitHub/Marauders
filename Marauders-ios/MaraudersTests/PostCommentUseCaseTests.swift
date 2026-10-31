//
//  PostCommentUseCaseTests.swift
//  Marauders
//

import Foundation
import Testing

@testable import Marauders

@MainActor
struct PostCommentUseCaseTests {
    private func makeSUT() -> (PostCommentUseCase, StubCommentRepository) {
        let repository = StubCommentRepository()
        return (PostCommentUseCase(repository: repository), repository)
    }

    @Test func surroundingWhitespaceIsRemovedBeforeTheRequest() async throws {
        let (useCase, repository) = makeSUT()

        _ = try await useCase.execute(videoID: UUID(), body: "  hi \n")

        #expect(repository.posts.map(\.body) == ["hi"])
    }

    @Test func textWithNothingVisibleIsRefusedWithoutARequest() async {
        for body in ["", "   \n", "\u{200B}\u{FE0F}", "\u{2800}", "\u{FFFC}"] {
            let (useCase, repository) = makeSUT()

            await #expect(throws: CommentError.invalidBody) {
                _ = try await useCase.execute(videoID: UUID(), body: body)
            }

            #expect(repository.posts.isEmpty)
        }
    }

    @Test func textOverTheLimitIsRefusedWithoutARequest() async {
        let (useCase, repository) = makeSUT()
        let tooLong = String(repeating: "a", count: CommentRules.maxCharacters + 1)

        await #expect(throws: CommentError.invalidBody) {
            _ = try await useCase.execute(videoID: UUID(), body: tooLong)
        }

        #expect(repository.posts.isEmpty)
    }
}
