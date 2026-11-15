//
//  UploadProgressLog.swift
//  MaraudersTests
//

import Foundation

@testable import Marauders

/// Remembers what an upload reported. A progress handler is called on whatever thread the transfer runs on while the
/// test reads the values, which the lock makes safe.
nonisolated final class UploadProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [Double] = []

    /// Every fraction reported so far, in the order it arrived.
    var values: [Double] { lock.withLock { reported } }

    /// Hand this to an upload as its `progress`.
    var handler: UploadProgressHandler {
        { [self] fraction in lock.withLock { reported.append(fraction) } }
    }
}
