//
//  BackgroundExecution.swift
//  Marauders
//

import UIKit

/// Time to finish work that is running when the app leaves the screen.
@MainActor
enum BackgroundExecution {
    /// Asks iOS for time to finish what is running (about 30 seconds once the app leaves the screen). Answers how to
    /// give it back; calling that twice is harmless. If the time runs out first, the task is ended and nothing else
    /// happens.
    static func begin(_ name: String) -> @MainActor () -> Void {
        let task = BackgroundTask(name: name)
        return { task.end() }
    }
}

@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
