//
//  DubbedAudioCacheEnvironment.swift
//  Marauders
//

import SwiftUI

extension EnvironmentValues {
    /// The saved AI audio that viewers share. `AppRootView` installs the real one from the composition root; `nil`
    /// until something does.
    @Entry var dubbedAudioCache: (any DubbedAudioCaching)? = nil
}
