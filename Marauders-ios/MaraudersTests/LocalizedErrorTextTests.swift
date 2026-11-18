//
//  LocalizedErrorTextTests.swift
//  MaraudersTests
//

import Foundation
import Testing

@testable import Marauders

/// The English text of every error of Domain and Data that a viewer can be shown. The texts are localized
/// (`String(localized:)`) and the unit tests run in English, so each one reads exactly as it did when it was a plain
/// string.
@MainActor
struct LocalizedErrorTextTests {
    private static let rows: [(label: String, actual: String?, expected: String)] = [
        ("CommentError.signInRequired", CommentError.signInRequired.errorDescription, "Sign in required"),
        ("CommentError.notFound", CommentError.notFound.errorDescription, "Comment or clip not found"),
        (
            "CommentError.invalidBody", CommentError.invalidBody.errorDescription,
            "A comment must be 1 to 500 characters"
        ),
        (
            "CommentError.rateLimited", CommentError.rateLimited.errorDescription,
            "Too many comments, try again shortly"
        ),
        ("CommentError.invalidResponse", CommentError.invalidResponse.errorDescription, "Invalid server response"),
        (
            "CommentError.serverError", CommentError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        ("ClipLikeError.signInRequired", ClipLikeError.signInRequired.errorDescription, "Sign in required"),
        ("ClipLikeError.notFound", ClipLikeError.notFound.errorDescription, "Clip not found"),
        ("ClipLikeError.rateLimited", ClipLikeError.rateLimited.errorDescription, "Too many likes, try again shortly"),
        ("ClipLikeError.invalidResponse", ClipLikeError.invalidResponse.errorDescription, "Invalid server response"),
        (
            "ClipLikeError.serverError", ClipLikeError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        ("FollowListError.signInRequired", FollowListError.signInRequired.errorDescription, "Sign in required"),
        ("FollowListError.notFound", FollowListError.notFound.errorDescription, "Profile not found"),
        (
            "FollowListError.rateLimited", FollowListError.rateLimited.errorDescription,
            "Too many requests, try again shortly"
        ),
        (
            "FollowListError.invalidResponse", FollowListError.invalidResponse.errorDescription,
            "Invalid server response"
        ),
        (
            "FollowListError.serverError", FollowListError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        (
            "LocationSharingError.signInRequired", LocationSharingError.signInRequired.errorDescription,
            "Sign in required"
        ),
        (
            "LocationSharingError.rateLimited", LocationSharingError.rateLimited.errorDescription,
            "Too many changes, try again shortly"
        ),
        (
            "LocationSharingError.invalidResponse", LocationSharingError.invalidResponse.errorDescription,
            "Invalid server response"
        ),
        (
            "LocationSharingError.serverError", LocationSharingError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        ("UserFollowError.signInRequired", UserFollowError.signInRequired.errorDescription, "Sign in required"),
        ("UserFollowError.notFound", UserFollowError.notFound.errorDescription, "Profile not found"),
        (
            "UserFollowError.cannotFollowSelf", UserFollowError.cannotFollowSelf.errorDescription,
            "You can't follow yourself"
        ),
        (
            "UserFollowError.rateLimited", UserFollowError.rateLimited.errorDescription,
            "Too many follows, try again shortly"
        ),
        (
            "UserFollowError.invalidResponse", UserFollowError.invalidResponse.errorDescription,
            "Invalid server response"
        ),
        (
            "UserFollowError.serverError", UserFollowError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        (
            "UserLocationAPIError.notAuthenticated", UserLocationAPIError.notAuthenticated.errorDescription,
            "Sign in required"
        ),
        (
            "UserLocationAPIError.serverError", UserLocationAPIError.serverError(503).errorDescription,
            "Location report failed (status 503)"
        ),
        (
            "UserLocationAPIError.invalidResponse", UserLocationAPIError.invalidResponse.errorDescription,
            "Invalid server response"
        ),

        (
            "UpdateAvatarError.unreadableImage", UpdateAvatarError.unreadableImage.errorDescription,
            "Couldn’t read that image — try another"
        ),

        ("ClipUploadError.unavailable", ClipUploadError.unavailable.errorDescription, "Uploading is not available"),
        (
            "ClipUploadError.alreadyUploading", ClipUploadError.alreadyUploading.errorDescription,
            "An upload is already in progress"
        ),
        (
            "ClipUploadError.notEnoughSpace", ClipUploadError.notEnoughSpace.errorDescription,
            "Not enough free space on this iPhone to upload the clip"
        ),

        (
            "VideoUploadAPIError.fileTooLarge", VideoUploadAPIError.fileTooLarge.errorDescription,
            "Video must be 100 MB or smaller"
        ),
        (
            "VideoUploadAPIError.unsupportedFormat", VideoUploadAPIError.unsupportedFormat.errorDescription,
            "Only MP4 / MOV is supported"
        ),
        (
            "VideoUploadAPIError.notAuthenticated", VideoUploadAPIError.notAuthenticated.errorDescription,
            "Sign in required to upload"
        ),
        (
            "VideoUploadAPIError.serverError", VideoUploadAPIError.serverError(503).errorDescription,
            "Upload failed (status 503)"
        ),
        (
            "VideoUploadAPIError.invalidResponse", VideoUploadAPIError.invalidResponse.errorDescription,
            "Invalid server response"
        ),

        (
            "UserProfileAPIError.notAuthenticated", UserProfileAPIError.notAuthenticated.errorDescription,
            "Sign in required"
        ),
        ("UserProfileAPIError.notFound", UserProfileAPIError.notFound.errorDescription, "Profile not found"),
        (
            "UserProfileAPIError.handleTaken", UserProfileAPIError.handleTaken.errorDescription,
            "That handle is already taken"
        ),
        (
            "UserProfileAPIError.invalidHandle", UserProfileAPIError.invalidHandle.errorDescription,
            "Handles may use letters, numbers, dots and underscores"
        ),
        (
            "UserProfileAPIError.invalidResponse", UserProfileAPIError.invalidResponse.errorDescription,
            "Invalid server response"
        ),
        (
            "UserProfileAPIError.serverError", UserProfileAPIError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        (
            "HTTPClientError.invalidResponse", HTTPClientError.invalidResponse.errorDescription,
            "Invalid server response"
        ),
        // A transport failure carries the system's own text and passes it on as it is.
        ("HTTPClientError.transport", HTTPClientError.transport("offline").errorDescription, "offline"),

        ("FeedAPIError.invalidLimit", FeedAPIError.invalidLimit.errorDescription, "Invalid number of clips requested"),
        ("FeedAPIError.invalidResponse", FeedAPIError.invalidResponse.errorDescription, "Invalid API response format"),
        (
            "FeedAPIError.serverError", FeedAPIError.serverError(503).errorDescription,
            "Server responded with status 503"
        ),

        (
            "SessionRefreshUnavailableError", SessionRefreshUnavailableError().errorDescription,
            "The service is temporarily unavailable. Please try again."
        ),

        (
            "VideoExportError.notExportable", VideoExportError.notExportable.errorDescription,
            "Couldn’t convert video to MP4"
        ),
        ("VideoExportError.exportFailed", VideoExportError.exportFailed.errorDescription, "Video conversion failed"),
    ]

    @Test func everyErrorKeepsItsEnglishText() {
        #expect(Self.rows.count == 52)
        for row in Self.rows {
            #expect(row.actual == row.expected, Comment(rawValue: row.label))
        }
    }
}
