//
//  VideoFeedPageView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedPageView: View {
    let video: FeedVideo
    let isActive: Bool

    var body: some View {
        LoopingVideoPlayerView(url: video.streamURL, isActive: isActive)
            .ignoresSafeArea()
            .background(Color.black)
    }
}
