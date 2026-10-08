//
//  FeedSampleData.swift
//  Marauders
//

import Foundation

enum FeedSampleData {
    static let videos: [FeedVideo] = [
        FeedVideo(
            streamURL: URL(
                string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
            )!
        ),
        FeedVideo(
            streamURL: URL(
                string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
            )!
        ),
    ]
}
