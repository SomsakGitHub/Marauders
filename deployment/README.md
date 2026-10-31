# Marauders — Deploy (Neon + Cloudflare)

ภาพรวมโปรเจกต์และสถาปัตยกรรม: [README.md](../README.md) · [ARCHITECTURE.md](../ARCHITECTURE.md)

สแต็ก: **Neon (Postgres)** เก็บ metadata · **Cloudflare Workers** เป็น API (`marauders-api`) · **R2** เก็บไฟล์ (bucket `marauders-videos`, binding `VIDEOS`)

- การปรับวิดีโอฝั่งเซิร์ฟเวอร์ (faststart, HLS): [video-pipeline.md](./video-pipeline.md)
- ระบบพากย์เสียง AI: [AI_DUBBING.md](./AI_DUBBING.md)

Worker deploy ด้วยมือ (`npm run deploy`) — CI ไม่ได้ deploy Worker; `Jenkinsfile` ทำเฉพาะ build แอปแล้วส่ง TestFlight (ดู [iOS / CI](#4-ios--ci))

## ลำดับ deploy

**รัน migration ก่อน แล้วค่อย deploy Worker** ที่ต้องใช้ schema ใหม่ — ไม่งั้น Worker ใหม่จะ query คอลัมน์/ตารางที่ยังไม่มี

## 1. Neon

1. เปิด [Neon Console](https://console.neon.tech/app/org-dawn-glade-96157792/projects) → เลือกโปรเจกต์ (หรือสร้างใหม่)
2. **Connect** → copy **connection string** (แนะนำ **pooled** สำหรับ Workers)
3. ใส่ใน `backend/.dev.vars` เป็น `DATABASE_URL=…` (ไฟล์นี้ gitignore; `scripts/migrate.mjs` อ่านจากที่นี่) และตั้งเป็น Wrangler secret ในขั้น 2

### Migration

```bash
cd backend
npm run db:migrate
```

`db:migrate` (`scripts/migrate.mjs`) รัน `backend/sql/` ตามลำดับ: `001` → `003`, แล้ว `005` → `017` (รวม `002_seed.sql` ซึ่งตอนนี้เป็นแค่คอมเมนต์ ไม่มีข้อมูลเดโม)

- **ไม่รัน `004_purge_feed_videos.sql`** — ลบทุกแถวใน `feed_videos` ต้องรันเองด้วยมือเมื่อจำเป็น (แนะนำ `npm run db:purge` ซึ่งลบทั้ง DB และ R2)
- `db:migrate` อ่าน `DATABASE_URL` จาก `backend/.dev.vars` เท่านั้น (ไม่อ่าน `wrangler secret`) — ก่อน deploy ต้องให้ค่านี้ชี้ production ไม่ใช่ dev branch ของ Neon
- ไม่มีตารางติดตามว่ารันไฟล์ไหนแล้ว: รันทุกไฟล์ใหม่หมดทุกครั้ง และหยุดทันทีเมื่อ statement ใด error จึงเขียนทุกไฟล์ให้รันซ้ำได้ (`IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` ก่อน `ADD CONSTRAINT` ฯลฯ)
- ไฟล์ใหม่ต้องเพิ่มชื่อใน array ใน `scripts/migrate.mjs` ด้วย ไม่งั้นไม่ถูกรัน
- script แยก statement ด้วย `;` — อย่าใส่ `;` ในคอมเมนต์ของไฟล์ SQL
- หรือจะวางไฟล์ใน Neon **SQL Editor** ทีละไฟล์ตามลำดับก็ได้

## 2. Cloudflare

1. เปิด [Cloudflare Dashboard](https://dash.cloudflare.com/b131b12456fbb5e37718f5cdba8f36ec/home)
2. ติดตั้ง CLI: `npm install` ใน `backend/`
3. Login: `npx wrangler login`
4. สร้าง R2 bucket (ครั้งเดียว — `wrangler.toml` ผูก binding `VIDEOS` กับชื่อนี้อยู่แล้ว):

   ```bash
   cd backend
   npx wrangler r2 bucket create marauders-videos
   ```

   Worker เขียน/อ่านไฟล์ผ่าน binding โดยตรง (`POST /v1/videos`, `GET /v1/media/…`) ไม่ต้องเปิด public access และไม่ต้องแก้ `stream_url` เอง ใช้ key prefix: `videos/` (คลิป), `avatars/` (รูปโปรไฟล์), `translations/` (เสียงพากย์ AI)

5. ตั้ง secret (ไม่ commit ลง git):

   ```bash
   npx wrangler secret put DATABASE_URL
   npx wrangler secret put JWT_SIGNING_SECRET   # openssl rand -base64 48
   npx wrangler secret put APPLE_CLIENT_ID      # com.somsak.Marauders
   npx wrangler secret put DEV_LOGIN_SECRET     # ไม่บังคับ — ≥ 32 ตัวอักษร เปิด /v1/auth/dev สำหรับ Simulator; production ไม่ต้องตั้ง
   ```

6. รัน migration ตามหัวข้อ [Migration](#migration) (ก่อน deploy)

7. Deploy:

   ```bash
   npm run deploy      # wrangler deploy
   ```

   `wrangler.toml` ยังประกาศ Rate Limiting binding `RATE_LIMITER` (120 req/60 วิ) และ `AUTH_RATE_LIMITER` (30 req/60 วิ) — เป็นด่านแรก (ถ้าไม่มี binding จะปล่อยผ่าน) ส่วนตัวตัดสินจริงของ auth/upload อยู่ใน Neon: auth 30 ครั้ง/60 วิ ต่อ IP และ upload 10 ครั้ง/60 วิ ต่อผู้ใช้ (ค่าตั้งใน `src/index.ts`, ตัวนับใน `src/db/rateLimit.ts`, ตาราง `010_rate_limit_counters.sql`)

8. Smoke check:

   ```bash
   curl "https://marauders-api.js6ctz7gtj.workers.dev/health"              # {"status":"ok"}
   curl "https://marauders-api.js6ctz7gtj.workers.dev/v1/feed?limit=5"
   ```

   ฟีดว่าง (`{"items":[],"viewerID":null}`) เป็นเรื่องปกติถ้ายังไม่มีใครอัปโหลด — seed ถูกปิดไว้

   ความคิดเห็นของคลิปที่มีอยู่ (ต้องรัน migration `017` แล้ว): `curl "https://marauders-api.js6ctz7gtj.workers.dev/v1/videos/<id>/comments"` ได้ `{"items":[],"nextCursor":null}` ถ้ายังไม่มีใครคอมเมนต์ ถ้าได้ 500 ให้เปิด `npx wrangler tail` แล้วยิงซ้ำ — Worker log `comments list|create|delete failed <SQLSTATE> <ข้อความของฐานข้อมูล>` (ไม่มีข้อความคอมเมนต์) เช่น `42P01` = ยังไม่ได้รัน `017` log นี้เห็นได้เฉพาะตอน `wrangler tail` เปิดอยู่ (`wrangler.toml` ไม่ได้เปิด `[observability]` จึงไม่เก็บย้อนหลัง)

### ตรวจก่อน deploy

```bash
cd backend
npm run typecheck        # tsc --noEmit
npm run test:feed
npm run test:dubbed-audio
npm run test:dev-auth
npm run test:comments
```

นอกจากนี้มี `scripts/test-audio-assessment.mjs` (ไม่มี npm script รันด้วย `node scripts/test-audio-assessment.mjs`, ทำงานในเครื่อง) ส่วน `scripts/test-upload.mjs` **ไม่ใช่เช็คก่อน deploy** — ยิง POST ไฟล์ปลอมไปที่ URL production โดยไม่มี Authorization จึงได้ 401

## 3. Local API

```bash
cd backend
cp .env.example .dev.vars   # ใส่ DATABASE_URL, JWT_SIGNING_SECRET, APPLE_CLIENT_ID
npx wrangler dev            # หรือ npm run dev
```

`wrangler dev` และ `db:migrate` อ่านจาก `.dev.vars` (ไม่ใช่ `.env`)

## 4. iOS / CI

แก้ `Marauders-ios/Marauders/APIConfiguration.plist` → key `MARAUDERS_API_BASE_URL` (แนะนำ — อ่านจาก bundle ได้เสมอ)

หรือใน Xcode → Build Settings → `INFOPLIST_KEY_MARAUDERS_API_BASE_URL`:

```text
https://<your-worker>.workers.dev
```

(ไม่มี slash ท้าย URL)

แนะนำชี้แอปไปที่ `*.workers.dev` ที่ deploy แล้ว (HTTPS); ล็อกอินบน Simulator ดู dev login ใน [README.md](../README.md)

**Jenkins** (`Jenkinsfile`): stage `Checkout` → `Install dependencies` → `Resolve Swift packages` → `Deploy to TestFlight` (`bundle exec fastlane beta`, เฉพาะ branch `main`) stage `Unit tests` และ `Coverage report` ถูก comment ไว้ชั่วคราว ('Temporarily disabled') จึงยังไม่รันทดสอบใน CI

ที่ Jenkins ต้องมี: agent label `macos`, Homebrew Ruby + bundler, และ credentials `jfrog-sdk-swift-token` (Resolve Swift packages และ Deploy), `asc-api-key` (file), `asc-key-id`, `asc-issuer-id` (Deploy — ถ้าไม่มี fastlane จะ error เพราะ `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH` ไม่ได้ตั้ง) lane `beta` build Release .ipa แล้ว upload ด้วย pilot โดยไม่รอ Apple ประมวลผล job รันได้ทีละ build และ timeout 90 นาที
