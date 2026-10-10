# Marauders — Deploy (Neon + Cloudflare)

ภาพรวมโปรเจกต์และสถาปัตยกรรม: [README.md](../README.md)

สแต็ก: **Neon (Postgres)** เก็บ metadata ฟีด · **Cloudflare Workers** เป็น API · **R2** เก็บไฟล์วิดีโอ

การปรับวิดีโอฝั่งเซิร์ฟเวอร์ (faststart, HLS): [video-pipeline.md](./video-pipeline.md)

## 1. Neon

1. เปิด [Neon Console](https://console.neon.tech/app/org-dawn-glade-96157792/projects) → เลือกโปรเจกต์ (หรือสร้างใหม่)
2. **SQL Editor** → รันตามลำดับ:
   - `backend/sql/001_schema.sql`
   - `backend/sql/002_seed.sql`
3. **Connect** → copy **connection string** (แนะนำ **pooled** สำหรับ Workers)

## 2. Cloudflare

1. เปิด [Cloudflare Dashboard](https://dash.cloudflare.com/b131b12456fbb5e37718f5cdba8f36ec/home)
2. ติดตั้ง CLI: `npm install` ใน `backend/`
3. Login: `npx wrangler login`
4. สร้าง R2 bucket (จำเป็นสำหรับอัปโหลดวิดีโอ):

   ```bash
   cd backend
   npx wrangler r2 bucket create marauders-videos
   ```

5. ตั้ง secret (ไม่ commit ลง git):

   ```bash
   npx wrangler secret put DATABASE_URL
   npx wrangler secret put JWT_SIGNING_SECRET   # openssl rand -base64 48
   npx wrangler secret put APPLE_CLIENT_ID      # com.somsak.Marauders
   ```

   รัน migration (รวม `006_app_users_and_ownership.sql`):

   ```bash
   npm run db:migrate
   ```

6. Deploy:

   ```bash
   npm run deploy
   ```

7. ทดสอบ:

   ```bash
   curl "https://marauders-api.js6ctz7gtj.workers.dev/v1/feed?limit=5"
   ```

### วิดีโอบน R2 (ทางเลือก)

1. **R2** → Create bucket `marauders-videos`
2. อัปโหลด `.mp4` → เปิด public access ผ่าน custom domain หรือ `r2.dev` (ตามนโยบายบัญชี)
3. อัปเดต `feed_videos.stream_url` ใน Neon ให้เป็น URL `https://...` ของไฟล์ใน R2
4. Uncomment `[[r2_buckets]]` ใน `backend/wrangler.toml` ถ้าจะเพิ่ม endpoint อัปโหลดภายหลัง

## 3. iOS

แก้ `Marauders-ios/Marauders/APIConfiguration.plist` → key `MARAUDERS_API_BASE_URL` (แนะนำ — อ่านจาก bundle ได้เสมอ)

หรือใน Xcode → Build Settings → `INFOPLIST_KEY_MARAUDERS_API_BASE_URL`:

```text
https://<your-worker>.workers.dev
```

(ไม่มี slash ท้าย URL)

รันแอป — แท็บ **ฟีด** เรียก `GET /v1/feed` · แท็บ **อัปโหลด** ส่ง `POST /v1/videos` (เก็บไฟล์ใน R2 bucket `marauders-videos`)

## Local API

```bash
cd backend
cp .env.example .env   # ใส่ DATABASE_URL จริง
npx wrangler dev
```

สำหรับ Simulator ต้องใช้ HTTPS หรือเพิ่ม ATS exception — แนะนำ deploy Workers แล้วชี้แอปไปที่ `*.workers.dev`
