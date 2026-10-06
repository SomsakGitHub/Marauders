//
//  VideoFeedView.swift
//  Marauders
//

import SwiftUI

struct VideoFeedView: View {
    private let videos: [FeedVideo]

    @State private var currentVideoID: FeedVideo.ID?

    init(videos: [FeedVideo] = FeedSampleData.videos) {
        self.videos = videos
        _currentVideoID = State(initialValue: videos.first?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoFeedPageView(
                            video: video,
                            isActive: currentVideoID == video.id
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(video.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentVideoID)
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

#Preview {
    VideoFeedView()
}
