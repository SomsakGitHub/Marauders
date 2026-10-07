-- Demo feed rows (replace stream_url with your Cloudflare R2 public URLs when ready).

-- Demo streams (HTTPS, playable in AVPlayer). Replace with your R2 URLs after upload.
INSERT INTO feed_videos (stream_url, author_name, caption, music_title, sort_order)
VALUES
    (
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8',
        '@marauders',
        'เช็ค atmosphere ตอนเย็น',
        'Original Sound — Marauders',
        50
    ),
    (
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
        '@crew_alpha',
        'วันหยุดที่ไม่มีแผน = แผนที่ดีที่สุด',
        'Lo-fi Drive — Studio Kit',
        40
    )
;
