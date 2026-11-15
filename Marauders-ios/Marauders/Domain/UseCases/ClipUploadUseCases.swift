//
//  ClipUploadUseCases.swift
//  Marauders
//

import Foundation

struct StartClipUploadUseCase: Sendable {
    private let uploader: any ClipUploading

    init(uploader: any ClipUploading) {
        self.uploader = uploader
    }

    /// Returns once the uploader has taken the clip on, not once it is uploaded.
    func execute(_ request: ClipUploadRequest) async throws {
        try await uploader.start(request)
    }
}

struct ObserveClipUploadUseCase: Sendable {
    private let uploader: any ClipUploading

    init(uploader: any ClipUploading) {
        self.uploader = uploader
    }

    /// The upload's current snapshot first, then every change.
    func execute() async -> AsyncStream<UploadSnapshot> {
        await uploader.snapshots()
    }
}

struct RetryClipUploadUseCase: Sendable {
    private let uploader: any ClipUploading

    init(uploader: any ClipUploading) {
        self.uploader = uploader
    }

    func execute() async {
        await uploader.retry()
    }
}

struct DiscardClipUploadUseCase: Sendable {
    private let uploader: any ClipUploading

    init(uploader: any ClipUploading) {
        self.uploader = uploader
    }

    func execute() async {
        await uploader.discard()
    }
}

struct ReconcileClipUploadUseCase: Sendable {
    private let uploader: any ClipUploading

    init(uploader: any ClipUploading) {
        self.uploader = uploader
    }

    func execute() async {
        await uploader.reconcile()
    }
}

/// The five things a screen, a sign out or a sign in asks of the uploader, so each takes one argument.
struct ClipUploadUseCases: Sendable {
    let start: StartClipUploadUseCase
    let observe: ObserveClipUploadUseCase
    let retry: RetryClipUploadUseCase
    let discard: DiscardClipUploadUseCase
    let reconcile: ReconcileClipUploadUseCase

    init(uploader: any ClipUploading) {
        start = StartClipUploadUseCase(uploader: uploader)
        observe = ObserveClipUploadUseCase(uploader: uploader)
        retry = RetryClipUploadUseCase(uploader: uploader)
        discard = DiscardClipUploadUseCase(uploader: uploader)
        reconcile = ReconcileClipUploadUseCase(uploader: uploader)
    }
}
