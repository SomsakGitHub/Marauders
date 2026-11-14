//
//  DubbingViewModelEnvironment.swift
//  Marauders
//

import SwiftUI

/// Builds the view model that dubs one clip. The composition root's factory carries the saved AI audio that viewers
/// share and the on-device services behind it, which a clip player cannot name itself.
struct DubbingViewModelFactory {
    let make: () -> DubbingViewModel
}

extension EnvironmentValues {
    /// `AppRootView` installs the real factory from the composition root; `nil` until something does.
    @Entry var dubbingViewModelFactory: DubbingViewModelFactory? = nil
}
