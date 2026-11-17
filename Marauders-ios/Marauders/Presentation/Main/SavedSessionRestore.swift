//
//  SavedSessionRestore.swift
//  Marauders
//

import Foundation

/// What the app does with the saved session when it opens, and again each time it comes to the foreground.
///
/// `ContentView` runs it. It is kept out of the view so that a test can run it too.
@MainActor
struct SavedSessionRestore {
    let authViewModel: AuthViewModel
    let friendLocationsViewModel: FriendLocationsViewModel

    /// The app opened: brings the saved session back.
    func run() async {
        await authViewModel.restoreSession()
        // A saved session that did not come back (expired or revoked) ended without a sign-out, so the iPhone stops
        // sending that account's location while the app is closed. One that could not be read has not ended, and
        // nothing is stopped for it.
        if !authViewModel.isSignedIn, !authViewModel.storedSessionIsUnavailable {
            friendLocationsViewModel.reset(signedOut: true)
        }
    }

    /// The app came to the foreground. A launch in the background before the iPhone's first unlock cannot read the
    /// saved session and decides nothing about it, so it is asked again now, and each time after until it can be read.
    func runAgainIfTheSessionWasNotRead() async {
        guard authViewModel.storedSessionIsUnavailable else { return }
        await run()
    }
}
