# Video pipeline (server-side)

เป้าหมาย: ให้ AVPlayer เริ่มเล่นเร็ว (faststart) และทางเลือก **HLS** แบบ adaptive-friendly สำหรับฟีด

## สิ่งที่ Worker ทำอัตโนมัติ

### MP4 faststart ตอนอัปโหลด

`POST /v1/videos` รับ MP4 แล้วย้าย atom `moov` ไว้ก่อน `mdat` (ใน memory, ไฟล์ ≤ 80 MB) ก่อน `put` ลง R2 — เทียบเท่า `ffmpeg -movflags +faststart` สำหรับ progressive download + HTTP Range

ไฟล์ MOV ยังเก็บตามเดิม (ไม่ remux ใน Worker)

### เสิร์ฟ media

`GET /v1/media/...` รองรับ:

| Path | ประเภท |
|------|--------|
| `videos/{uuid}.mp4` / `.mov` | Progressive |
| `videos/{uuid}/master.m3u8` | HLS playlist |
| `videos/{uuid}/segNNN.ts` | HLS segment |

Headers: `Accept-Ranges: bytes`, `Cache-Control: public, immutable`, `ETag` + `304` เมื่อ client ส่ง `If-None-Match`

## HLS (ทางเลือก — ใกล้ TikTok มากกว่า MP4 เดี่ยว)

Worker **ไม่** รัน ffmpeg — ใช้สคริปต์บนเครื่อง dev:

```bash
cd backend

# <feed_videos.id> จาก GET /v1/feed (ฟิลด์ id) — ไม่ใช่ชื่อไฟล์ใน R2
npm run video:hls -- --env staging <feed_videos.id>
```

ต้องระบุ `--env staging|production` เสมอ (ไม่มีค่า default; ตอนนี้ยังไม่มี staging จึงใช้ได้แต่ `--env production`): สคริปต์อ่านฐานข้อมูลจาก `backend/.dev.vars.<env>` และอ่าน bucket กับ URL ของ Worker จาก `backend/environments.json` (ไม่ต้องตั้ง `MARAUDERS_API_ORIGIN` แล้ว) การอัปโหลดขึ้น R2 ใช้ `wrangler r2 object put --remote` กับ bucket ของ environment นั้น และ production ถามให้พิมพ์ `production` ก่อน

ถ้าไม่ส่งไฟล์ local สคริปต์จะ **ดาวน์โหลด MP4 ปัจจุบัน** จาก `stream_url` (ของ Worker environment นั้น) แล้วแปลง

สคริปต์จะ:

1. สร้าง HLS 720p (segment ~2s) ด้วย ffmpeg  
2. อัปโหลด `master.m3u8` + `seg*.ts` ไป R2 ใต้ `videos/{object-uuid}/` (uuid เดียวกับไฟล์ `.mp4` เดิม)  
3. อัปเดต `feed_videos.stream_url` เป็น URL playlist บน Worker  

แอป iOS ใช้ `streamURL` เดิม — AVPlayer เล่น HLS ได้โดยไม่ต้องเปลี่ยน API

การตัดสินใจฝั่งเล่นวิดีโอ: [docs/adr/001-feed-playback-dual-player.md](../docs/adr/001-feed-playback-dual-player.md)

### ติดตั้ง ffmpeg

- macOS: `brew install ffmpeg`  
- Linux: แพ็กเกจ distro ของคุณ  

## Deploy หลังแก้ backend

```bash
cd backend
npm run deploy:staging       # (หลังสร้าง staging แล้ว) npm test ทั้งชุด (รวม typecheck) → แผน migration → migration → deploy → ตรวจ /health
npm run deploy:production    # ถามให้พิมพ์ production
```

ดูลำดับและ rollback ใน [README.md](./README.md#ลำดับ-deploy)

## ข้อจำกัด Cloudflare Workers

- Remux faststart ใน Worker จำกัดขนาด ~80 MB (หลีกเลี่ยง OOM)  
- Transcode หลาย bitrate / คิวยาว ควรใช้ **บริการแยก** (เช่น Cloudflare Stream, container + ffmpeg, หรือ CI รัน `hls-transcode-r2.mjs`) แทนการทำใน `fetch` handler
