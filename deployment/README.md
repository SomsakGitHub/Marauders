# Marauders — Deploy (Neon + Cloudflare)

ภาพรวมโปรเจกต์และสถาปัตยกรรม: [README.md](../README.md) · [ARCHITECTURE.md](../ARCHITECTURE.md) · เหตุผลของการแยก environment: [ADR-010](../docs/adr/010-environments.md)

สแต็ก: **Neon (Postgres)** เก็บ metadata · **Cloudflare Workers** เป็น API · **R2** เก็บไฟล์ (binding `VIDEOS`) — กำหนดไว้ 2 environment คือ **staging** และ **production** (ตารางด้านล่าง) แต่**ตอนนี้ใช้ production ตัวเดียว** (เจ้าของตัดสินใจ 2026-11-20): staging ยังไม่ได้สร้าง resource ใด ๆ ใน Neon, R2 หรือ Cloudflare และแอปทั้งสอง build (**Staging** ที่รันจาก Xcode กับ **Production** ที่ขึ้น TestFlight) ก็ชี้ production — ดู [ADR-010](../docs/adr/010-environments.md)

- การปรับวิดีโอฝั่งเซิร์ฟเวอร์ (faststart, HLS): [video-pipeline.md](./video-pipeline.md)
- ระบบพากย์เสียง AI: [AI_DUBBING.md](./AI_DUBBING.md)

Worker deploy ด้วยมือจากเครื่องของเจ้าของโปรเจกต์ (`npm run deploy:production`; `npm run deploy:staging` ใช้ได้หลังสร้าง staging แล้ว) — CI ไม่ได้ deploy และไม่มี key ของ Cloudflare หรือ Neon (GitHub Actions รันแค่เทสต์ออฟไลน์ ดู [docs/ci-cd.md](../docs/ci-cd.md)); `Jenkinsfile` ทำเฉพาะ build แอปแล้วส่ง TestFlight (ดู [iOS / CI](#4-ios--ci))

## Environments

| | staging | production |
|---|---|---|
| สถานะ | **ยังไม่ได้สร้าง** (กำหนดไว้ในโค้ดและเอกสารแล้ว) | **ใช้งานอยู่** — ตัวเดียวที่มีตอนนี้ |
| ใช้ทำอะไร | (เมื่อสร้างแล้ว) build Staging ของแอป, `npm run dev`, ซ้อม migration, ทดลองอัปโหลด, dev login | แอปจริง (TestFlight / App Store) **และตอนนี้รวมถึง build Staging ของแอป (รันจาก Xcode / Simulator), ทดลองอัปโหลด, dev login** |
| `--env` ของ script | `--env staging` | `--env production` |
| wrangler | `--env staging` | ไม่ใส่ `--env` (config ระดับบนของ `wrangler.toml`) |
| Worker | `marauders-api-staging` | `marauders-api` |
| URL | `https://marauders-api-staging.js6ctz7gtj.workers.dev` | `https://marauders-api.js6ctz7gtj.workers.dev` |
| R2 bucket | `marauders-videos-staging` | `marauders-videos` |
| Neon | database ของ staging เอง (ว่าง สร้างด้วย migration) | database เดิม |
| ไฟล์ vars ในเครื่อง | `backend/.dev.vars.staging` | `backend/.dev.vars.production` |
| dev login (`/v1/auth/dev`) | เปิด (มี `DEV_LOGIN_SECRET` ของตัวเอง) | **เปิดอยู่** ระหว่างมี backend ตัวเดียว (Simulator ใช้) — ปิดเมื่อมี staging แล้ว |
| observability (Workers Logs) | เปิด | ปิด |
| rate-limit namespace | `1002` | `1001` |

ตารางที่ script อ่านจริงคือ `backend/environments.json` (ชื่อ Worker, URL, bucket, ไฟล์ vars, phrase ยืนยัน) — ตัว Production guard ของแอปอ่านไฟล์เดียวกัน เปลี่ยนค่าที่ไฟล์นี้ที่เดียว

### กติกา

- ทุกคำสั่งที่แตะข้อมูลต้องมี `--env staging|production` และ **ไม่มีค่า default** — ยกเว้น `npm run dev` (รัน staging เสมอ ไม่มี production จึงยังเริ่มไม่ได้จนกว่าจะสร้าง staging) ระหว่างนี้คำสั่งที่ใส่ `--env staging` จะหยุดที่ไฟล์ `.dev.vars.staging` ที่ยังไม่มี (ส่วน `test-upload --env staging` จะยิงไปหา Worker ที่ยังไม่มีอยู่จริง)
- แต่ละคำสั่งอ่านเฉพาะไฟล์ vars ของ environment ที่สั่ง ไม่อ่าน `backend/.dev.vars` เดิม (ไม่มีชื่อ environment) แล้ว: ถ้าไฟล์นั้นยังมีค่าของ production อยู่ ให้ย้ายเป็น `.dev.vars.production` (เก็บบรรทัด `DEV_LOGIN_SECRET` ไว้ด้วย เพราะ build Staging ของแอปบน Simulator ใช้ — ดูแถว dev login ในตาราง)
- ไฟล์ vars สองไฟล์ห้ามชี้ database เดียวกัน (server เดียวกันและชื่อ database เดียวกัน; pooled กับ direct ของ server เดียวกันนับว่าเป็นอันเดียวกัน, role/password/option ไม่นับ): ทุกคำสั่งและ `npm run dev` จะหยุดพร้อมบอกชื่อสองไฟล์ (ไม่พิมพ์ค่า) ถ้าเผลอ copy ไฟล์ production ไปเป็น staging
- ทุกคำสั่งพิมพ์ banner ก่อน: environment, Worker, URL, database (host และชื่อ ไม่มี credential), bucket — ดูให้ตรงก่อนปล่อยให้ทำต่อ
- เขียนลง production ต้อง**พิมพ์ phrase ยืนยัน** (`production`; ลบข้อมูล `purge staging` / `purge production`) ที่เทอร์มินัล หรือส่ง `--confirm "<phrase>"` เมื่อไม่มีเทอร์มินัล — ไม่มี flag ที่ข้ามการยืนยัน
- **ห้ามรัน `npx wrangler deploy` เปล่า ๆ (ไม่ใส่ `--env`)** — wrangler จะ deploy ไป production แล้วแค่เตือน ไม่มี script หรือ `package.json` ไหนรันคำสั่งนี้ ให้ deploy ผ่าน `npm run deploy:<env>` เท่านั้น
- ข้อมูลแต่ละ environment แยกกันทั้งหมด (ผู้ใช้, คลิป, token): token ของ Worker หนึ่งใช้กับอีกตัวไม่ได้ และ `stream_url` / `avatar_url` ที่ Worker เก็บเป็น URL เต็มของ host ที่เขียนแถวนั้น

### เมื่อจะสร้าง staging (ยังไม่ได้ทำ)

ทำก่อนเปิดให้คนทั่วไปใช้, เชิญ tester ภายนอก หรือเมื่อมีนักพัฒนาคนที่สอง — ขั้นไหนที่แตะ cloud ต้องถามเจ้าของก่อนทุกครั้ง:

1. สร้าง database ใหม่ที่ว่างใน Neon และเก็บ connection string (pooled) ใน `backend/.dev.vars.staging` (หัวข้อ 1), สร้าง R2 bucket `marauders-videos-staging` และตั้ง secret ด้วย `wrangler secret bulk` (หัวข้อ 2) — `JWT_SIGNING_SECRET` และ `DEV_LOGIN_SECRET` ของ staging สุ่มใหม่ ไม่ใช้ซ้ำกับ production
2. `npm run db:migrate -- --env staging` สองรอบ (รอบสองต้องไม่มีอะไรเปลี่ยน) แล้ว `npm run deploy:staging` — เทียบ URL ที่ wrangler พิมพ์กับ `backend/environments.json` ถ้าต่างให้แก้ทุกที่ที่ `grep -rn marauders-api-staging` เจอ
3. ชี้ build Staging ของแอปไป staging ใน**สามที่พร้อมกัน**: build setting `MARAUDERS_API_BASE_URL` ของ configuration `Debug-Staging`, ชื่อไฟล์ `.dev.vars.staging` ใน `Shared/Configuration/DevLogin.swift` และค่า `DEBUG_ENVIRONMENT` ใน `backend/test/scripts/iosEnvironments.test.mjs` (เทสต์ล้มจนกว่าสามที่จะตรงกัน) พร้อมแก้ชื่อและค่าที่คาดไว้ใน `APIBaseURLTests` (`theDebugBuildReceivesProductionThroughInfoPlist`)
4. ย้าย `DEV_LOGIN_SECRET` ไปไว้ที่ staging แล้วลบของ production: `npx wrangler secret delete DEV_LOGIN_SECRET` และตรวจว่า `/v1/auth/dev` ของ production ตอบ `404`

## ลำดับ deploy

คำสั่งเดียวทำให้ครบทุกขั้นตามลำดับ และหยุดที่ขั้นแรกที่ล้ม:

```bash
cd backend
npm run deploy:staging               # หลังสร้าง staging แล้วเท่านั้น
npm run deploy:production            # ถามให้พิมพ์ production; ไม่มีเทอร์มินัล: -- --confirm production
```

1. banner (environment, Worker, URL, database, bucket) และเลขเวอร์ชัน (commit 7 ตัว; ต่อท้าย `-dirty` ถ้า `backend/` มีการแก้ที่ยังไม่ commit)
2. production เท่านั้น: ปฏิเสธถ้า `backend/` มีการแก้ที่ยังไม่ commit (เพื่อให้เลขเวอร์ชันใน `/health` ตรงกับ commit ที่มีจริง)
3. login ของ Cloudflare: `wrangler whoami --json` ต้องตอบว่า login อยู่ ไม่งั้นหยุดและบอกให้รัน `npx wrangler login` — เช็กก่อน `npm test` เพราะ login ที่หมดอายุไม่งั้นจะโผล่ตอน `wrangler deploy` ซึ่งเป็นหลังเทสต์ หลัง phrase และหลัง migration ไปแล้ว (script ไม่พิมพ์คำตอบของ wrangler เพราะมีอีเมลของบัญชี)
4. `npm test` ทั้งชุด
5. แผน migration (dry run): แสดงไฟล์ที่ยังไม่ได้รัน และหยุดถ้าไฟล์ที่เคยรันไปแล้วถูกแก้ — เห็นก่อนพิมพ์ phrase
6. phrase ยืนยัน (production)
7. จดเวอร์ชันของ Worker ที่ใช้งานอยู่ตอนนี้ (ไว้ทำคำสั่ง rollback)
8. migration ที่ยังไม่ได้รัน (ดู [Migration](#migration)) — **migration ก่อน deploy Worker เสมอ** ไม่งั้น Worker ใหม่จะ query คอลัมน์/ตารางที่ยังไม่มี
9. `wrangler deploy --env <env> --var GIT_SHA:<เวอร์ชัน>`
10. เรียก `<url>/health` ซ้ำจนกว่าจะตอบ environment และเวอร์ชันที่เพิ่ง deploy (Worker รุ่นเก่าอาจยังตอบอีกไม่กี่วินาที)
11. พิมพ์คำสั่ง rollback

ถ้า deploy ไปแล้วแต่ `/health` ไม่ตรง script จะแจ้งว่าล้มพร้อมคำสั่ง rollback — **ไม่มี rollback อัตโนมัติ** เพราะการเปลี่ยน database ย้อนไม่ได้ เจ้าของโปรเจกต์เป็นคนตัดสิน

`npm run deploy` เปล่า ๆ จะแจ้งว่าต้องระบุ `--env` (ไม่มี environment ตั้งต้น)

### Rollback

```bash
npx wrangler rollback <version-id> --name marauders-api-staging   # หลังสร้าง staging แล้ว
npx wrangler rollback <version-id> --name marauders-api
npx wrangler deployments list --name marauders-api        # ดูประวัติ + version-id
```

`<version-id>` คือบรรทัดที่ `deploy:<env>` พิมพ์ท้ายสุด (`to undo this … deploy: …`) — rollback คืนทั้ง version ของ Worker คือโค้ดและ bindings ของ version นั้น (Cloudflare บอกว่า version เก็บ bindings แต่ไม่ได้เอ่ยถึง var ตรง ๆ ให้ถือว่า var อย่าง `GIT_SHA` ย้อนตามไปด้วยจนกว่าจะลองจริง) **ไม่ย้อน migration** ตารางหรือคอลัมน์ที่เพิ่มไปแล้วปล่อยทิ้งไว้ได้ถ้า Worker รุ่นเก่าไม่แตะมัน

### `/health`

```bash
curl "https://marauders-api-staging.js6ctz7gtj.workers.dev/health"   # (หลังสร้าง staging แล้ว) {"status":"ok","environment":"staging","version":"1d02680"}
curl "https://marauders-api.js6ctz7gtj.workers.dev/health"           # {"status":"ok","environment":"production","version":"1d02680"}
```

`environment` มาจาก `[vars] ENVIRONMENT` ใน `wrangler.toml` ส่วน `version` คือเลขที่ `deploy:<env>` ใส่ให้ (`GIT_SHA`) — Worker ที่ deploy ด้วยวิธีอื่นจะขึ้น `"version":"dev"` ใช้เทียบว่า Worker ที่รันอยู่คือ commit ไหน

### ยกระดับ build ขั้นต่ำ (force update)

แอปรู้ว่า build เลขต่ำสุดที่ยังใช้ได้คือเท่าไรจาก **Firebase Remote Config** แอปที่เลข build ต่ำกว่านั้นจะขึ้นหน้า "ต้องอัปเดตแอป" แทนตัวแอป (เหตุผลและขอบเขตดู [ADR-012](../docs/adr/012-force-update.md)) ค่ามาจากสอง parameter ใน Firebase console: `minimum_build` (ชนิด Number; `0` หรือว่างคือไม่บังคับ) กับ `update_url` (ชนิด String; ลิงก์ของปุ่มอัปเดต) — **ไม่ต้อง commit และไม่ต้อง deploy Worker** เลข build คือ `BUILD_NUMBER` ของ Jenkins (`CFBundleVersion`) — build ที่ไม่ได้มาจาก Jenkins รวมถึงการกด Run จาก Xcode เป็น build 1 เสมอ และ**ถูกบล็อกเหมือน build อื่น**เมื่อตั้ง `minimum_build` เกิน 1 — ยกเว้น build Debug (Run ของ scheme Staging) ซึ่ง**ไม่มีวันถูกบล็อก** build ที่เลขเท่ากับค่าขั้นต่ำก็ผ่าน ก่อนกด Run scheme Production บนเครื่องเพื่องานอื่น ให้ตั้ง `minimum_build` เป็น `0` ก่อน

ตั้งค่า**เมื่อ build N ติดตั้งได้จริงจาก TestFlight แล้วเท่านั้น** (ต่อไปคือ App Store) และห้ามตั้งเกินเลข build ล่าสุดที่อัปโหลดแล้ว ไม่งั้นผู้ใช้เจอหน้า "ต้องอัปเดต" ทั้งที่ยังไม่มีอะไรให้อัปเดต ส่วน build ที่ยังไม่มีด่านนี้ (ทุกรุ่นก่อน build แรกที่มีฟีเจอร์นี้) หยุดด้วยวิธีนี้ไม่ได้

**ตั้งครั้งแรก (ทำครั้งเดียว):**

1. ใน [Firebase console](https://console.firebase.google.com) สร้างโปรเจกต์โดย**ปิด Google Analytics** แล้วเพิ่มแอป iOS ที่ bundle id `com.somsak.Marauders`
2. ดาวน์โหลด `GoogleService-Info.plist` — ไฟล์นี้ไม่อยู่ใน git (repo เป็น public) เก็บใน Jenkins เป็น credential ชนิด **Secret file** ID `marauders-firebase-plist` ([docs/ci-cd.md](../docs/ci-cd.md)) เพื่อให้ build ส่ง TestFlight ได้ไฟล์เอง และถ้าจะลองบนเครื่องให้วางไว้ที่ `Marauders-ios/Marauders/GoogleService-Info.plist` (`.gitignore` กันไว้แล้ว) lane `beta` หยุดก่อน build ถ้าไฟล์หาย เป็นของแอปอื่น หรือมีคีย์ที่ SDK เริ่มจากมันไม่ได้ (`GOOGLE_APP_ID`, `API_KEY`, `PROJECT_ID`, `GCM_SENDER_ID`)
3. ใน Remote Config สร้าง parameter `minimum_build` (Number ค่า `0`) กับ `update_url` (String ค่าว่าง) แล้วกด **Publish changes**
4. ก่อน build ที่ถึงผู้ทดสอบ ตอบคำถาม App Privacy ใน App Store Connect ให้ตรงกับ SDK (ติ๊กข้อมูลวินิจฉัยที่ SDK เก็บ — คำตอบเป็นของเจ้าของแอป)

**ยกระดับ (ทุกครั้ง):**

1. ใน Remote Config ตั้ง `minimum_build` = N และ `update_url` = ลิงก์ที่เป็น `https` บน `apple.com` หรือ `*.apple.com` (เช่น `https://apps.apple.com/app/id<เลขแอป>` หรือลิงก์ TestFlight) ไม่มี user, password หรือ port — **ไม่มีอะไรตรวจค่าในคอนโซลให้** แอปคือด่านเดียว: ลิงก์ที่ไม่ผ่านกติกา แอปจะไม่บล็อกใครเลย และเลขที่พิมพ์ผิด (เช่น `12o`, `1.5`, `-3`) แอปอ่านเป็น `0` คือไม่บล็อก
2. กด **Publish changes** — ไม่มี review หรือเทสต์ก่อนถึงเครื่องผู้ใช้ จึงตรวจเลขกับลิงก์ให้ดีก่อนกด
3. รอ: แอปที่เปิดใหม่หรือกลับมา foreground จะรู้ภายในราว 1 ชั่วโมง (SDK ดึงจาก Google อย่างมากชั่วโมงละครั้ง และแอปถามอย่างมากทุก 10 นาที) ไม่ใช่ทันที แอปที่ยังเปิดค้างอยู่จะรู้ตอนกลับมา foreground ครั้งถัดไป
   ดูได้ใน log ของแอป (หมวด `update`): บรรทัด `config refreshed: minimumBuild=<n>` ลงท้ายด้วย `(from Google)` เมื่อ Google เพิ่งตอบ
   หรือ `(from the SDK's saved values, Google last asked N min ago)` เมื่อ SDK ตอบจากค่าที่เก็บไว้ (ยังไม่ครบชั่วโมง เลยยังเป็นเลขเดิม)
   ถ้าอยากเห็นค่าใหม่บนเครื่องทดสอบทันที ให้ลบแอปแล้วติดตั้งใหม่

**ย้อน:** ตั้ง `minimum_build` เป็น `0` (หรือลบ parameter) แล้ว **Publish changes** — ไม่ต้อง commit, deploy หรือ rollback อะไร หน้า "ต้องอัปเดต" จะหายเองเมื่อแอปถามครั้งถัดไป (เปิดใหม่หรือกลับมา foreground ภายในราว 1 ชั่วโมงเหมือนกัน) โดยไม่ต้องติดตั้งแอปใหม่ ถ้าเผลอตั้งสูงเกินไปให้ย้อนทันที เพราะเครื่องที่จำค่านั้นไว้แล้วและติดต่อ Firebase ไม่ได้จะติดหน้าเดิมต่อจนกว่าจะติดต่อได้

## 1. Neon

> **ตอนนี้ใช้ production ตัวเดียว** — ขั้นของ staging ในหัวข้อ 1 และ 2 (database, bucket, secret, deploy) คือวิธีสร้าง staging เมื่อถึงเวลา ยังไม่ได้ทำ ดู [เมื่อจะสร้าง staging](#เมื่อจะสร้าง-staging-ยังไม่ได้ทำ)

1. เปิด [Neon Console](https://console.neon.tech/app/org-dawn-glade-96157792/projects)
2. **production:** ใช้ database เดิม · **staging:** สร้าง **database ใหม่ที่ว่าง** (project ใหม่ หรือ database ใหม่ใน project เดิม) — **อย่าใช้ branch ของ production** เพราะจะได้ข้อมูลผู้ใช้จริง (รวมตำแหน่ง) ติดมา
3. **Connect** → copy **connection string** (แนะนำ **pooled** สำหรับ Workers)
4. ใส่ `DATABASE_URL=…` ในไฟล์ vars ของ environment นั้น: `backend/.dev.vars.staging` หรือ `backend/.dev.vars.production` (สร้างจาก `.dev.vars.example` — ไฟล์พวกนี้ gitignore; `scripts/migrate.mjs` และ `deploy` อ่านจากที่นี่) และตั้งเป็น Wrangler secret ของ Worker นั้นในขั้น 2

### Migration

```bash
cd backend
npm run db:migrate -- --env staging --dry-run       # (หลังสร้าง staging แล้ว) ดูว่าจะรันไฟล์ไหนบ้าง ไม่แตะอะไร
npm run db:migrate -- --env staging                 # (หลังสร้าง staging แล้ว)
npm run db:migrate -- --env production --dry-run
npm run db:migrate -- --env production              # ถามให้พิมพ์ production
```

(ต้องมี `--` คั่นก่อน flag ของ script ไม่งั้น npm จะเอา `--env` ไปเป็นค่าของตัวเอง)

`db:migrate` (`scripts/migrate.mjs`) หาไฟล์ `backend/sql/NNN_*.sql` เองแล้วรันตามเลข ไม่ต้องเพิ่มชื่อไฟล์ที่ไหน (รวม `002_seed.sql` ซึ่งตอนนี้เป็นแค่คอมเมนต์ ไม่มีข้อมูลเดโม)

- **มีตารางติดตาม** `schema_migrations(name, sha256, applied_at)` ในแต่ละ database: ไฟล์จะถูกบันทึกก็ต่อเมื่อทุก statement ของมันรันสำเร็จ รอบถัดไปรันเฉพาะไฟล์ที่ยังไม่ถูกบันทึก ถ้า statement ใด error จะหยุดทันทีและไฟล์นั้นยังไม่ถูกบันทึก
- **ไม่รัน `004_purge_feed_videos.sql`** — ลบทุกแถวใน `feed_videos` ต้องรันเองด้วยมือเมื่อจำเป็น (แนะนำ `npm run db:purge -- --env <env>` ซึ่งลบทั้ง DB และ R2)
- ถ้าไฟล์ที่รันไปแล้วถูกแก้ทีหลัง (sha256 ไม่ตรง) script จะหยุดและบอกชื่อไฟล์ — ถ้าตั้งใจแก้และไฟล์รันซ้ำได้ ให้รันใหม่พร้อม `--accept-changed <ชื่อไฟล์>` (ใส่ได้หลายไฟล์)
- ไฟล์ที่เลขต่ำกว่าไฟล์ที่รันไปแล้ว (สอง branch เพิ่ม migration พร้อมกัน) ยังรัน แต่ script เตือนว่า out of order
- **ไฟล์ใหม่ต้องรันซ้ำได้** (`IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` ก่อน `ADD CONSTRAINT` ฯลฯ): production ไม่เคยมีตารางติดตาม การรันครั้งแรกจึงรันทุกไฟล์อีกรอบ (เหมือนที่เคยเป็นทุกครั้ง) แล้วบันทึกไว้
- script แยก statement ด้วย `;` — อย่าใส่ `;` ในคอมเมนต์ของไฟล์ SQL
- หรือจะวางไฟล์ใน Neon **SQL Editor** ทีละไฟล์ตามลำดับก็ได้ (แต่จะไม่ถูกบันทึกในตารางติดตาม)

## 2. Cloudflare

1. เปิด [Cloudflare Dashboard](https://dash.cloudflare.com/b131b12456fbb5e37718f5cdba8f36ec/home)
2. ติดตั้ง CLI: `npm install` ใน `backend/`
3. Login: `npx wrangler login`
4. สร้าง R2 bucket (ครั้งเดียวต่อ environment — `wrangler.toml` ผูก binding `VIDEOS` กับชื่อเหล่านี้อยู่แล้ว):

   ```bash
   cd backend
   npx wrangler r2 bucket create marauders-videos-staging    # ยังไม่ได้สร้าง (ดู "เมื่อจะสร้าง staging")
   npx wrangler r2 bucket create marauders-videos            # production มีอยู่แล้ว
   ```

   Worker เขียน/อ่านไฟล์ผ่าน binding โดยตรง (`POST /v1/videos`, `GET /v1/media/…`) ไม่ต้องเปิด public access และไม่ต้องแก้ `stream_url` เอง ใช้ key prefix: `videos/` (คลิป), `avatars/` (รูปโปรไฟล์), `translations/` (เสียงพากย์ AI)

5. ตั้ง secret ของแต่ละ Worker (ไม่ commit ลง git):

   ```bash
   # staging (ยังไม่ได้ทำ): ส่งทั้งไฟล์ vars ของ staging ในคำสั่งเดียว
   npx wrangler secret bulk .dev.vars.staging --env staging

   # production: secret ที่มีอยู่แล้วคงไว้ แก้ทีละตัว (ไม่ใส่ --env = production)
   npx wrangler secret put DATABASE_URL
   npx wrangler secret put JWT_SIGNING_SECRET   # openssl rand -base64 48
   npx wrangler secret put APPLE_CLIENT_ID      # com.somsak.Marauders

   # ลบบัญชี (ไม่บังคับ — ไม่ตั้งก็ใช้งานอื่นได้ปกติ แต่ DELETE /v1/users/me จะตอบ 503): วิธีสร้างกุญแจอยู่ในหัวข้อ "ลบบัญชี" ข้างล่าง
   npx wrangler secret put APPLE_TEAM_ID        # Team ID 10 ตัวอักษร
   npx wrangler secret put APPLE_KEY_ID         # Key ID 10 ตัวอักษรของกุญแจ Sign in with Apple
   npx wrangler secret put APPLE_PRIVATE_KEY < /path/to/AuthKey_XXXXXXXXXX.p8   # ส่งไฟล์ .p8 ทาง stdin ค่าไม่ผ่านแชต ไม่ลง log ไม่ลง repo
   ```

   `DEV_LOGIN_SECRET` (≥ 32 ตัวอักษร เปิด `/v1/auth/dev` สำหรับ Simulator): **ตอนนี้ production มีและต้องมีต่อไป** เพราะ build Staging ของแอปบน Simulator คุยกับ production (ค่าเดียวกันเก็บใน `.dev.vars.production` ให้แอปอ่าน) — ใครถือ secret นี้สร้างผู้ใช้ `dev:<label>`, คลิปและคอมเมนต์ทดสอบบน backend จริงได้ (ล็อกอินเป็นผู้ใช้จริงไม่ได้ เพราะ `apple_sub` ของ dev ขึ้นต้น `dev:`) **เมื่อสร้าง staging แล้ว**ให้ย้ายไปตั้งเฉพาะ staging (อยู่ใน `.dev.vars.staging`) แล้วลบของ production: `npx wrangler secret delete DEV_LOGIN_SECRET` แล้วตรวจว่า `curl -s -o /dev/null -w "%{http_code}\n" -X POST https://marauders-api.js6ctz7gtj.workers.dev/v1/auth/dev` ได้ `404` ใช้ `JWT_SIGNING_SECRET` คนละค่ากันระหว่าง environment (token ของอีกตัวจะถูกปฏิเสธ)

6. รัน migration ตามหัวข้อ [Migration](#migration) (`deploy:<env>` ทำให้อยู่แล้วก่อน deploy)

7. Deploy ตามหัวข้อ [ลำดับ deploy](#ลำดับ-deploy):

   ```bash
   npm run deploy:staging      # หลังสร้าง staging แล้วเท่านั้น
   npm run deploy:production
   ```

   (staging ที่เพิ่งสร้าง: deploy ครั้งแรกให้ได้ Worker ก่อน แล้วค่อยตั้ง secret ตามขั้น 5 — `/health` ไม่ใช้ secret เลยผ่านได้)

   `wrangler.toml` ยังประกาศ Rate Limiting binding `RATE_LIMITER` (120 req/60 วิ) และ `AUTH_RATE_LIMITER` (30 req/60 วิ) ทั้งสอง environment (namespace `1001` production, `1002` staging) — เป็นด่านแรก (ถ้าไม่มี binding จะปล่อยผ่าน) ส่วนตัวตัดสินจริงของ auth/upload อยู่ใน Neon: auth 30 ครั้ง/60 วิ ต่อ IP และ upload 10 ครั้ง/60 วิ ต่อผู้ใช้ (ค่าตั้งใน `src/index.ts`, ตัวนับใน `src/db/rateLimit.ts`, ตาราง `010_rate_limit_counters.sql`)

   Wrangler environment **ไม่สืบทอดอะไรจากระดับบน** (binding, vars, observability) — `[env.staging]` ใน `wrangler.toml` จึงเขียนซ้ำทั้งหมด และเทสต์ `test/scripts/parity.test.mjs` จะล้มถ้าสองฝั่งไม่ตรงกัน เวลาเพิ่ม binding ใหม่ให้เพิ่มทั้งสองที่

8. Smoke check (ใส่ `URL` เป็นของ environment ที่เพิ่ง deploy):

   ```bash
   curl "$URL/health"             # {"status":"ok","environment":"staging","version":"…"}
   curl "$URL/v1/feed?limit=5"
   ```

   ฟีดว่าง (`{"items":[],"viewerID":null}`) เป็นเรื่องปกติถ้ายังไม่มีใครอัปโหลด — seed ถูกปิดไว้ และ staging ว่างเสมอจนกว่าจะอัปโหลดผ่านแอป

   ความคิดเห็นของคลิปที่มีอยู่ (ต้องรัน migration `017` แล้ว): `curl "$URL/v1/videos/<id>/comments"` ได้ `{"items":[],"nextCursor":null}` ถ้ายังไม่มีใครคอมเมนต์ ถ้าได้ 500 ให้เปิด `npx wrangler tail` (staging: `npx wrangler tail --env staging`) แล้วยิงซ้ำ — Worker log `comments list|create|delete failed <SQLSTATE> <ข้อความของฐานข้อมูล>` (ไม่มีข้อความคอมเมนต์) เช่น `42P01` = ยังไม่ได้รัน `017` log นี้เห็นได้ตอน `wrangler tail` เปิดอยู่ (staging เปิด `[env.staging.observability]` จึงเก็บย้อนหลังด้วย; production ไม่เปิด — สามเส้นทางยัง log error object ของ driver ทั้งก้อนซึ่งอาจมีค่าของแถว)

**ก่อน deploy Worker ที่มีไลก์ ต้องรัน migration `018` ก่อนเสมอ** (`deploy:<env>` ทำตามลำดับนี้ให้ แต่ถ้าสลับลำดับเอง): query ของฟีดนับไลก์จากตาราง `video_likes` ถ้า deploy ก่อนรัน migration ฟีดจะตอบ 500 `failed to load feed` ทุกคำขอ (ต่างจากความคิดเห็นที่พังแค่ชีต) ตรวจหลัง deploy: `curl "$URL/v1/feed?limit=1"` ต้องได้ `likeCount` ในทุก item ถ้าได้ 500 ให้เปิด `npx wrangler tail` จะเห็น `42P01` (ไม่มีตาราง `video_likes`)

**ก่อน deploy Worker ที่รับ `Idempotency-Key` ต้องรัน migration `023` ก่อนเสมอ:** คำขอ `POST /v1/videos` ที่ส่ง header นี้จะอ่านและเขียนคอลัมน์ `feed_videos.upload_key` ถ้ายังไม่มีคอลัมน์ Worker จะตอบ 500 `upload lookup failed` ส่วนคำขอที่ไม่มี header ไม่แตะคอลัมน์นี้ (แอปรุ่นเก่าที่ไม่ส่ง header จึงไม่เสีย) ตรวจหลังรัน migration แบบอ่านอย่างเดียว: ต้องมีคอลัมน์ `feed_videos.upload_key` และ index `feed_videos_owner_upload_key_uidx` คอลัมน์ที่เพิ่มปล่อยไว้ได้เพราะ Worker รุ่นเก่าไม่แตะมัน ถ้าต้องการเอาออกจริง: `ALTER TABLE feed_videos DROP COLUMN upload_key` (index หายไปพร้อมกัน)

### ลบบัญชี: กุญแจ Sign in with Apple และลำดับขึ้นระบบ

`DELETE /v1/users/me` (Settings → Delete Account) ลบบัญชีและทุกอย่างในบัญชีทันที และตามกฎของ Apple ต้องให้ Apple เพิกถอน token ของ Sign in with Apple ด้วย (ไม่งั้น Marauders ยังค้างอยู่ในรายการ Sign in with Apple ของผู้ใช้) Worker จึงต้องมีกุญแจของ Sign in with Apple เพื่อลงชื่อ client secret ที่ Apple รับ ใช้ secret สามตัว **ไม่บังคับ**: ถ้าไม่ตั้ง Worker ทำงานอื่นได้ปกติ แต่เส้นทางนี้ตอบ `503` สำหรับบัญชี Apple และแอปบอกว่า "ตอนนี้ยังลบบัญชีไม่ได้" (บัญชีทดสอบ `dev:` ไม่ใช้ Apple จึงลบได้เสมอ) เหตุผลและทางเลือกอยู่ใน [ADR-011](../docs/adr/011-account-deletion.md)

| Secret | ค่า | หาได้จาก |
|---|---|---|
| `APPLE_TEAM_ID` | Team ID 10 ตัวอักษร | developer.apple.com/account → **Membership details** (หรือมุมขวาบนของหน้า account) |
| `APPLE_KEY_ID` | Key ID 10 ตัวอักษรของกุญแจ | หน้ารายละเอียดของกุญแจที่สร้างข้างล่าง |
| `APPLE_PRIVATE_KEY` | เนื้อไฟล์ `.p8` ทั้งไฟล์ (ขึ้นต้น `-----BEGIN PRIVATE KEY-----`) | ไฟล์ที่ดาวน์โหลดตอนสร้างกุญแจ |

`client_id` ใน client secret คือ `APPLE_CLIENT_ID` ที่มีอยู่แล้ว (bundle id `com.somsak.Marauders`) Worker ลงชื่อ client secret ใหม่ทุกคำขอ (ES256, อายุ 5 นาที) ไม่เก็บอะไรไว้

**สร้างกุญแจ** (ทำครั้งเดียว โดยเจ้าของ Apple Developer account):

1. developer.apple.com/account → **Certificates, Identifiers & Profiles** → **Keys** → ปุ่ม **+**
2. ตั้งชื่อ (เช่น `Marauders Sign in with Apple`) ติ๊ก **Sign in with Apple** แล้วกด **Configure** → เลือก **Primary App ID** เป็น App ID ของแอป (`com.somsak.Marauders`) → Save → Continue → Register — กุญแจต้องผูกกับ App ID ของแอป ไม่งั้น Apple ตอบ `invalid_client`
3. หน้าถัดไปแสดง **Key ID** (จดไว้ = `APPLE_KEY_ID`) กด **Download** เพื่อได้ `AuthKey_<Key ID>.p8` — **ดาวน์โหลดได้ครั้งเดียว** ถ้าหายต้องเพิกถอนกุญแจแล้วสร้างใหม่ เก็บไฟล์ไว้ที่ปลอดภัยนอก repo ห้าม commit และห้ามส่งผ่านแชต
4. ถ้ากุญแจรั่ว: เพิกถอนใน **Keys** แล้วสร้างใหม่ ตั้ง secret ทั้งสองตัวที่เกี่ยวข้อง (`APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`) ใหม่

**ตั้ง secret บน production** ด้วย `wrangler secret put` (ตัวอย่างอยู่ในหัวข้อ 2 ขั้น 5) โดยส่งไฟล์ `.p8` ทาง stdin ส่วนใน `.dev.vars.<env>` (ใช้กับ `npm run dev` และ `wrangler secret bulk`) ให้เขียนกุญแจเป็นบรรทัดเดียวโดยใช้ `\n` แทนการขึ้นบรรทัด — Worker รับทั้งสองแบบ

**ลำดับขึ้นระบบ** — ทีละขั้น ต้องรอเจ้าของสั่งทุกขั้น:

| ขั้น | ทำอะไร |
|---|---|
| R0 (ไม่บังคับ, อ่านอย่างเดียว) | นับแถว `feed_videos` ใน production ที่ `stream_url` ลงท้าย `.m3u8` — ตัดสินว่า check A ต้องมีคลิป HLS ทดสอบไหม **ทำแล้ว 2026-11-21:** 17 คลิป ไม่มีคลิป HLS เลย (ทั้งตามนามสกุล `.m3u8` และตามรูปคีย์ `videos/<uuid>/…`) จึงไม่ต้องมีคลิป HLS ทดสอบใน check A |
| R1 secret และเพดาน | เจ้าของสร้างกุญแจแล้วตั้งสาม secret บน production (ข้างบน) ส่วนเพดาน `MAX_CLIPS_PER_DELETION` คำนวณแล้วเมื่อ 2026-11-21 สำหรับ Cloudflare Workers Free (50 subrequest ต่อคำขอ) ได้ **18** ใน `backend/src/routes/deleteAccount.ts`: 9 ครั้งคงที่ + 2 ต่อคลิป = 45 เหลือ 5 ไว้ให้ retry (นับจากโค้ดและตรวจด้วยเทสต์ ไม่ได้วัดบน Cloudflare จริง) ค่านี้ใช้ได้ตราบที่ production ไม่มีคลิป HLS เพราะแต่ละคลิป HLS เพิ่มอีก 2 ครั้ง ถ้าแผนของ Worker หรือเพดานของ Cloudflare เปลี่ยน ให้อ่านเพดานใหม่ คำนวณใหม่ และ commit พร้อมเหตุผล |
| R2 merge และ deploy | merge; จด version ที่ใช้งานอยู่ด้วย `npx wrangler deployments list` (เป็นเป้า rollback); `npm run deploy:production -- --confirm production` (script รันเทสต์และเช็ค login ของ Cloudflare เอง) **ไม่มี migration** Rollback: `npx wrangler rollback <version id>` — เส้นทางกลับเป็น `405` และแอปแสดง "ตอนนี้ยังลบบัญชีไม่ได้" |
| R3 check A (ไม่ใช้ Apple) | บน Simulator ด้วย build `Marauders Staging` ล็อกอินเป็นผู้ใช้ทดสอบ `dev:` อัปโหลดคลิปทดสอบ 1–2 คลิป (กับคลิป HLS 1 คลิปถ้า R0 พบว่ามี) แล้ว Settings → Delete Account → **Delete test user** ต้องได้ "Your account was deleted", คลิปหายจาก `GET /v1/feed`, key ของคลิปใน R2 หาย และแถว `app_users` หาย (ตรวจแบบอ่านอย่างเดียว) นี่คือหลักฐานจริงว่า `DELETE` ที่มี JSON body ผ่าน URLSession, Cloudflare และ Worker ครบ (ถ้า body ถูกตัดจะได้ `400`; ทางสำรองคือเปลี่ยนเป็น `POST /v1/users/me/delete`) |
| R4 check B (Apple จริง) | บน iPhone กับ Apple ID ที่ยอมเสียไป ลบบัญชีผ่านหน้าจอ Apple แล้วเปิด การตั้งค่า → Apple ID → Sign in with Apple ต้องไม่เห็น Marauders อีก; ล็อกอินใหม่ต้องได้บัญชีใหม่ที่ว่างเปล่า และ Marauders จะกลับมาอยู่ในรายการนั้นอีกครั้ง (นี่คือเหตุที่ Worker เพิกถอนสิทธิ์ที่การยืนยันซ้ำหลัง `204` หายสร้างขึ้นด้วย: การยืนยันกับ Apple หลังเพิกถอนสร้างสิทธิ์ใหม่ ถ้าไม่เห็น Marauders กลับมา สมมติฐานนั้นไม่จริงและเส้นทางนั้นไม่จำเป็น) นี่คือหลักฐานเดียวของการเพิกถอน เพราะ Apple ตอบ `200` ไม่ว่าจะได้รับ token อะไร |
| R5 TestFlight | หลังผ่าน check A และ B เท่านั้น เจ้าของเริ่ม Jenkins แล้วกด Build Now |

ลำดับมีผล: Worker ที่ยังไม่มีเส้นทางนี้ตอบ `405` และ Worker ที่มีเส้นทางแต่ยังไม่มี secret ตอบ `503` สำหรับบัญชี Apple ทุกบัญชี ทั้งสองกรณีแอปบอกว่า "ตอนนี้ยังลบบัญชีไม่ได้" App Review จะเจอข้อความนี้ถ้า build ไปถึงมือ reviewer ก่อนตั้ง secret จึงต้องทำ R1 ก่อน R2 และทำ R2 ถึง R4 ให้ครบก่อน R5

### ตรวจก่อน deploy

```bash
cd backend
npm test                 # ทั้งชุด — deploy:<env> รันให้เองก่อนทุกครั้ง
npm run typecheck        # tsc --noEmit
npm run test:scripts     # script และ guard ของ environment (targets, migrations, deploy, r2, purge, workflow)
npm run test:health
npm run test:feed
npm run test:dubbed-audio
npm run test:dev-auth
npm run test:comments
npm run test:likes
npm run test:auth-refresh
npm run test:upload-idempotency
npm run test:account-deletion
```

ทั้งหมดทำงานออฟไลน์ (database เป็นของปลอมในเครื่อง) นอกจากนี้มี `scripts/test-audio-assessment.mjs` (ไม่มี npm script รันด้วย `node scripts/test-audio-assessment.mjs`, ทำงานในเครื่อง) ส่วน `scripts/test-upload.mjs` **ไม่ใช่เช็คก่อน deploy** — ยิง POST ไฟล์ปลอมไปที่ URL ของ environment ที่เลือกโดยไม่มี Authorization จึงได้ 401 (ต้องใส่ `--env` เสมอ ตอนนี้จึงเป็น `--env production` ซึ่งต้องพิมพ์ phrase `production`)

### คำสั่งอื่นที่แตะข้อมูล

```bash
cd backend
npm run db:purge -- --env staging                   # ลบทุกแถว feed_videos + ไฟล์ใน R2 ของ environment นั้น ต้องพิมพ์ "purge staging"
npm run video:hls -- --env staging <feed_videos.id> # สร้าง HLS แล้วอัปโหลดขึ้น bucket ของ environment นั้น
```

ตอนนี้ยังไม่มี staging จึงใช้ได้แต่ `--env production`: `db:purge --env production` ลบทุกแถวของฟีดจริงและไฟล์ใน R2 ของ production (ต้องพิมพ์ `purge production`) — ไม่ควรรันถ้าไม่ได้ตั้งใจ

`db:purge` แสดงว่าจะลบเท่าไหร่ แล้วถาม phrase `purge <env>` **ก่อน**ลบ และถ้าลบไฟล์ใน R2 ไม่สำเร็จจะเก็บแถวไว้ให้รันซ้ำได้ — คำสั่ง R2 ใช้ `--remote` แล้ว (ก่อนหน้านี้ wrangler 4.150.0 ทำกับ simulator ในเครื่องแทน purge ครั้งก่อน ๆ จึงลบแต่แถวใน database) การ purge ครั้งแรกหลังแก้จึงลบไฟล์จริง ไม่รันกับ production ถ้าไม่จำเป็น การลบที่ wrangler ปฏิเสธนับเป็นความล้มเหลวทุกกรณี รวมถึงคีย์ที่ไม่มีอยู่จริง เพราะยังไม่เคยเห็นข้อความของ R2 ฝั่ง remote และแถวคือรายการเดียวที่บอกว่ามีไฟล์อะไร (ดู `scripts/lib/r2.mjs`): ถ้า R2 ปฏิเสธการลบคีย์ที่ไม่มี คลิป HLS ที่มี segment น้อยกว่า 200 จะหยุดที่ segment แรกที่ไม่มีและเก็บแถวไว้ จนกว่าจะเห็นข้อความจริงบน staging แล้วแยกมันออกจากความล้มเหลวจริงได้

## 3. Local API

```bash
cd backend
cp .dev.vars.example .dev.vars.staging   # ใส่ DATABASE_URL (ของ staging), JWT_SIGNING_SECRET, APPLE_CLIENT_ID, DEV_LOGIN_SECRET (APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY ใช้ตอนลบบัญชีเท่านั้น)
npm run dev                              # wrangler dev --env staging; พอร์ตอื่น: npm run dev -- --port 8788
```

**ตอนนี้ยังใช้ไม่ได้ เพราะยังไม่มี staging** (ขั้นตอนข้างบนไว้ใช้หลังสร้างแล้ว) `npm run dev` รัน **staging เท่านั้น** (ไม่มี production ในเครื่อง) และไม่เริ่มถ้าไม่มี `.dev.vars.staging` — ถ้าไม่ดักไว้ wrangler จะถอยไปอ่านไฟล์ vars ที่ไม่มีชื่อ environment ซึ่งอาจเป็นของ production ไม่รับ `--env` (ใช้ `npm run dev` ตามที่เขียนไว้เท่านั้น)

## 4. iOS / CI

**แอปอ่าน URL ของ Worker จาก Info.plist ที่เดียว** (key `MARAUDERS_API_BASE_URL`) ซึ่ง build เติมให้จาก build setting ชื่อเดียวกัน (Xcode → target Marauders → Build Settings → User-Defined → `MARAUDERS_API_BASE_URL`):

| Build (scheme) | Configuration | ค่า |
|---|---|---|
| Staging (`Marauders Staging`) | `Debug-Staging` | `https://marauders-api.js6ctz7gtj.workers.dev` (production — ตอนนี้มี backend ตัวเดียว; จะเป็น staging หลังสร้างแล้ว ดู "เมื่อจะสร้าง staging") |
| Production (`Marauders Production`) | `Release-Production` | `https://marauders-api.js6ctz7gtj.workers.dev` |

ชื่อ configuration ฝั่ง Staging ต้องมีคำว่า `Debug`: Xcode ให้ flag `DEBUG` กับ local package `MaraudersAuth` เฉพาะ configuration ที่ชื่อมีคำนี้ (configuration ชื่อ `Staging` เฉย ๆ ทำให้ `DevAuthAPIClient` compile ไม่ผ่าน) ตารางเต็มของสอง build (scheme, log ในแอป, dev login, guard) อยู่ในหัวข้อ "Staging และ Production" ของ [README.md](../README.md)

(ไม่มี slash ท้าย URL และไม่มี path) `Config/Info-Additions.plist` ส่งค่าเข้า Info.plist ที่ build เสร็จเป็น `$(MARAUDERS_API_BASE_URL)` — **ไม่มี `APIConfiguration.plist` ในแอปอีกแล้ว** และไม่ต้องใช้ `INFOPLIST_KEY_MARAUDERS_API_BASE_URL` (Xcode ข้ามชื่อ `INFOPLIST_KEY_` ที่มันไม่รู้จัก ค่านั้นจึงไม่เคยถึง Info.plist)

- **ชี้ build Staging ไปที่อื่น** (ตัวอย่าง: Worker ใน `wrangler dev` ผ่าน tunnel `https://…`): ตั้ง environment variable ชื่อเดียวกัน — ใน Xcode: Scheme → Run → Arguments → Environment Variables หรือจาก terminal `SIMCTL_CHILD_MARAUDERS_API_BASE_URL=https://… xcrun simctl launch …` ต้องเป็น `https://` ไม่มี path ค่าที่ผิดทำให้แอปหยุดแจ้ง error (ไม่ถอยกลับไปใช้ค่าจาก build เงียบ ๆ) และ **build Production ไม่อ่าน environment ของ process เลย**
- **ดูว่า build นี้คุยกับ Worker ตัวไหน:** แท็บ **Log** (build Staging เท่านั้น) มี subtitle `<host> (configured)` หรือ `<host> (override)` ต่อด้วย ` · client key: set` หรือ ` · client key: missing` (build นี้ได้ค่า `MARAUDERS_CLIENT_KEY` ไหม ไม่แสดงค่าจริง) และบรรทัด `[config] api base host=…` ใน log
- **dev login บน Simulator:** แอปอ่าน `DEV_LOGIN_SECRET` จาก `backend/.dev.vars.production` ของ checkout นี้ (ไฟล์ vars ของ environment ที่ build Staging ใช้) (หรือ `SIMCTL_CHILD_MARAUDERS_DEV_LOGIN_SECRET`) และ**เสนอปุ่มเฉพาะตอนที่แอปคุยกับ host ที่ build กำหนด** (`configured`) — ถ้าชี้ด้วย override จะไม่มีปุ่ม เพราะตัวแปรนั้นระบุ host ไหนก็ได้ แล้ว secret ต้องไม่ถูกส่งไปที่ที่ไม่ได้ตั้งใจ ดู dev login ใน [README.md](../README.md)
- **Production guard:** Run Script phase `Run Script release config check` (เฉพาะ configuration `Release-Production`) รัน `Marauders-ios/Scripts/check-release-config.sh` กับแอปที่ build เสร็จ แล้วทำให้ build ล้มถ้า `MARAUDERS_API_BASE_URL` ไม่ตรงกับ URL ของ production ใน `backend/environments.json`, มี `APIConfiguration.plist` ค้างในแอป หรือ executable มี type ที่ใช้เฉพาะ Debug (`DebugLogView` = แท็บ Log ในแอป, `DevAuthAPIClient` = dev login) — Jenkins build `Marauders Production` ไป TestFlight จึงอัปโหลด build ที่ชี้ผิดที่หรือมี log ในแอปไม่ได้ ถ้าจะเปลี่ยน URL ของ production ต้องแก้ทั้ง `environments.json` และ build setting ของ `Release-Production` (guard เทียบสองที่นี้) build Staging ข้าม phase นี้
- **หลังชี้ build Staging ไป staging:** เครื่องเดียวที่สลับ build Staging (backend staging) กับ TestFlight (production) ต้องล็อกอินใหม่ทุกครั้งที่สลับ (token ของ Worker หนึ่งอีกตัวไม่รับ และ Keychain ไม่แยกตาม host) และ build Staging จะเห็นฟีดว่างจนกว่าจะอัปโหลดคลิปขึ้น staging — ตอนนี้ build Staging กับ TestFlight คุย production ตัวเดียวกันจึงไม่เจอเรื่องนี้ แต่ข้อมูลทดสอบอยู่ปนกับของจริง

**CI ที่ GitHub** (`.github/workflows/backend.yml`): รัน `npm ci` + `npm test` เมื่อ push เข้า `main`, เมื่อมี pull request และสั่งมือได้ ไม่มี secret ไม่ deploy — รายละเอียดใน [docs/ci-cd.md](../docs/ci-cd.md)

**Jenkins** (`Jenkinsfile`): stage `Checkout` → `Install dependencies` → `Resolve Swift packages` → `Deploy to TestFlight` (`bundle exec fastlane beta`, เฉพาะ branch `main`) stage `Unit tests` และ `Coverage report` ถูก comment ไว้ชั่วคราว ('Temporarily disabled') จึงยังไม่รันทดสอบใน CI

ที่ Jenkins ต้องมี: agent label `macos`, Homebrew Ruby + bundler, และ credentials `jfrog-sdk-swift-token` (Resolve Swift packages และ Deploy), `asc-api-key` (file), `asc-key-id`, `asc-issuer-id` (Deploy — ถ้าไม่มี fastlane จะ error เพราะ `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH` ไม่ได้ตั้ง), `marauders-client-key` (Secret text, Deploy — ค่า build-time ที่ Jenkins ฝังเข้าแอปเป็น `MARAUDERS_CLIENT_KEY` ต้องเป็น `run by pass` เป๊ะๆ เพราะแอปเปิดได้เฉพาะ build ที่ถือค่านี้ ถ้าไม่มี credential นี้ stage Deploy จะหยุดก่อน build ดู [docs/ci-cd.md](../docs/ci-cd.md)) lane `beta` build .ipa ด้วย scheme `Marauders Production` (configuration `Release-Production`) แล้ว upload ด้วย pilot โดยไม่รอ Apple ประมวลผล job รันได้ทีละ build และ timeout 90 นาที
