//
//  UpdateAvatarUseCase.swift
//  Marauders
//

import Foundation

enum UpdateAvatarError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Couldn’t read that image — try another"
        }
    }
}

struct UpdateAvatarUseCase {
    private let repository: UserProfileRepository
    private let imagePreparer: AvatarImagePreparing

    init(repository: UserProfileRepository, imagePreparer: AvatarImagePreparing) {
        self.repository = repository
        self.imagePreparer = imagePreparer
    }

    /// Downscales the picked image and uploads it, returning the stored URL.
    func execute(rawImageData: Data) async throws -> URL {
        guard let jpeg = imagePreparer.prepareJPEG(from: rawImageData, maxDimension: 512) else {
            throw UpdateAvatarError.unreadableImage
        }
        return try await repository.updateAvatar(imageData: jpeg, mimeType: "image/jpeg")
    }
}
