-- Demo feed rows (replace stream_url with your Cloudflare R2 public URLs when ready).

INSERT INTO feed_videos (stream_url, author_name, caption, music_title, sort_order)
VALUES
    (
        'https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4',
        '@marauders',
        'เช็ค atmosphere ตอนเย็น',
        'Original Sound — Marauders',
        50
    ),
    (
        'https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4',
        '@crew_alpha',
        'วันหยุดที่ไม่มีแผน = แผนที่ดีที่สุด',
        'Lo-fi Drive — Studio Kit',
        40
    ),
    (
        'https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4',
        '@night_owl',
        'POV: เปิดแอปแล้วหยุดเลื่อนไม่ได้',
        'Pulse — Night Owl',
        30
    ),
    (
        'https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4',
        '@street_lens',
        'เก็บโมเมนต์สั้น ๆ ไว้ดูซ้ำ',
        'City Lights — Street Lens',
        20
    ),
    (
        'https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4',
        '@daily_clip',
        'ฟีดแรกของ Marauders',
        'Trending — Daily Clip',
        10
    )
;
