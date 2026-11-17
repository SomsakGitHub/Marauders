//
//  VideoThumbnailLoaderEnvironment.swift
//  Marauders
//

import SwiftUI

extension EnvironmentValues {
    /// The thumbnails of the map's pins and the profile's grid. `AppRootView` installs the real loader from the
    /// composition root; `nil` until something does.
    @Entry var videoThumbnailLoader: VideoThumbnailLoader? = nil
}
