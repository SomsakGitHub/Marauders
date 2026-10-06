//
//  FeedSampleData.swift
//  Marauders
//

import Foundation

enum FeedSampleData {
    /// Curated HTTPS sample streams for the demo feed (ATS-compliant).
    static let videos: [FeedVideo] = [
        FeedVideo(
            streamURL: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!,
            authorName: "@marauders",
            caption: "เช็ค atmosphere ตอนเย็น 🔥",
            musicTitle: "Original Sound — Marauders"
        ),
        FeedVideo(
            streamURL: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!,
            authorName: "@crew_alpha",
            caption: "วันหยุดที่ไม่มีแผน = แผนที่ดีที่สุด",
            musicTitle: "Lo-fi Drive — Studio Kit"
        ),
        FeedVideo(
            streamURL: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!,
            authorName: "@night_owl",
            caption: "POV: เปิดแอปแล้วหยุดเลื่อนไม่ได้",
            musicTitle: "Pulse — Night Owl"
        ),
        FeedVideo(
            streamURL: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
            authorName: "@street_lens",
            caption: "เก็บโมเมนต์สั้น ๆ ไว้ดูซ้ำ",
            musicTitle: "City Lights — Street Lens"
        ),
        FeedVideo(
            streamURL: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4")!,
            authorName: "@daily_clip",
            caption: "ฟีดแรกของ Marauders 🎬",
            musicTitle: "Trending — Daily Clip"
        ),
    ]
}
