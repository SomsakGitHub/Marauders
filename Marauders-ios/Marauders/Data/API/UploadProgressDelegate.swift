//
//  UploadProgressDelegate.swift
//  Marauders
//

import Foundation

/// Turns the byte counts a `URLSession` upload task reports into calls of an `UploadProgressHandler`.
///
/// It reports when the whole percent changes, so a clip of 100 MB makes at most 101 calls instead of one for every few
/// kilobytes, and the first count always reports. A transfer gets its own delegate: the last percent is remembered per
/// delegate, so a body that is sent again from the start (a replay after a 401) is reported again from 0.
nonisolated final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: UploadProgressHandler
    private let lock = NSLock()
    private var lastPercent: Int?

    init(handler: @escaping UploadProgressHandler) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        // An unknown total (-1) or an empty one (0) says nothing about how far the body has got.
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        let percent = Int(fraction * 100)
        let isNewPercent = lock.withLock {
            defer { lastPercent = percent }
            return lastPercent != percent
        }
        if isNewPercent { handler(fraction) }
    }
}
