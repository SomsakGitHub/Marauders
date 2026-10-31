# CI/CD — iOS (Jenkins → TestFlight)

Pipeline นี้รันบน **Jenkins (macOS)** ทำหน้าที่ build แล้วอัปโหลดขึ้น **TestFlight**
เมื่อ build บน `main`

> **สถานะปัจจุบัน:** stage **Unit tests** และ **Coverage report** ถูก comment ปิดไว้ใน
> `Jenkinsfile` ("Temporarily disabled to keep the TestFlight build fast") ดังนั้น CI
> **ไม่ได้รันเทสต์** ตอนนี้ — รันเองในเครื่องด้วย `fastlane test` (ดู "รันในเครื่อง")
> ก่อนจะเลิกปิด ให้ uncomment ทั้งสอง stage ใน `Jenkinsfile` และย้ายขึ้นมาไว้ก่อน Deploy ถ้าต้องการให้เทสต์ล้มแล้วไม่อัปโหลด

## ภาพรวม flow

ลำดับ stage ตาม `Jenkinsfile` ที่ทำงานอยู่จริง:

```
Checkout ─▶ Install dependencies ─▶ Resolve Swift packages ─▶ [เฉพาะ main] Deploy to TestFlight
                                                                   (fastlane beta = build + pilot)
```

ปิดอยู่ (comment ใน `Jenkinsfile`): `Unit tests` (`fastlane test`, `retry(2)`, JUnit) และ
`Coverage report` (`xccov` + `recordCoverage`) — โค้ดที่ comment ไว้อยู่ต่อจาก Deploy to TestFlight (ถ้าเปิดโดยไม่ย้าย เทสต์จะรันหลังอัปโหลดไปแล้ว ไม่ได้กั้น build)

ทุก stage ยกเว้น Deploy รันกับทุก branch ที่ job build; Deploy รันเฉพาะเมื่อ
`BRANCH_NAME == main` หรือ `GIT_BRANCH == origin/main` (job แบบ Pipeline ธรรมดาไม่ตั้ง
`BRANCH_NAME` จึงใช้ `GIT_BRANCH` แทน) ใน `Jenkinsfile` **ไม่มี `triggers {}`** —
การรันอัตโนมัติมาจาก webhook ที่ตั้งฝั่ง job/GitHub (ขั้นที่ 8)

ตัวเลือกของ pipeline: agent label `macos`, timeout 90 นาที, เก็บ build 20 ล่าสุด
(artifact 10), `disableConcurrentBuilds()`, timestamps

## ไฟล์ที่เกี่ยวข้อง

| ไฟล์ | หน้าที่ |
| --- | --- |
| `Jenkinsfile` | ประกาศ pipeline (stages, credentials, artifacts: `Marauders-ios/build/*.ipa` และ `Marauders-ios/build/test/Marauders.xcresult/**`) |
| `Marauders-ios/Gemfile` | ประกาศ `fastlane` (เวอร์ชันถูก pin โดย `Gemfile.lock` ที่ commit ไว้ เพื่อให้ Jenkins ใช้เวอร์ชันเดียวกัน) |
| `Marauders-ios/fastlane/Appfile` | `app_identifier` + `team_id` |
| `Marauders-ios/fastlane/Fastfile` | lane `test` (ไม่ได้ใช้ใน CI ตอนนี้), `build` (archive `.ipa` ไม่อัปโหลด), `beta` (เรียก `build` แล้วอัปโหลดด้วย `pilot`) |
| `Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders.xcscheme` | shared scheme (จำเป็นสำหรับ clean checkout) |

---

## เริ่มจากศูนย์ (Getting started)

> หมายเหตุ: Jenkins สำหรับ iOS ต้องรันบน **Mac** เท่านั้น (ต้องมี Xcode + Simulator)
> ถ้าอยากได้ Docker/VM แนะนำใช้ Mac mini เป็น agent

### ขั้นที่ 0 — เตรียมเครื่อง Mac

```bash
# 1) Command Line Tools + Xcode (ติดตั้ง Xcode จาก App Store ก่อน)
sudo xcodebuild -runFirstLaunch

# 2) Homebrew (ถ้ายังไม่มี) — https://brew.sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 3) เครื่องมือที่ pipeline ต้องใช้
brew install ruby                 # ให้ได้ Ruby 3.1+ (system ruby เก่าเกินไป)
brew install xcbeautify           # จัดรูปแบบ log ให้อ่านง่าย
brew install xcresultparser       # แปลง .xcresult → JUnit (รองรับ Swift Testing)

# 4) ตรวจว่าใช้งานได้
xcodebuild -version
ruby --version                    # ต้องเป็น 3.1 ขึ้นไป
```

เพิ่ม Homebrew Ruby เข้า `PATH` ถาวร (ใส่ท้าย `~/.zshrc`):

```bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
```

### ขั้นที่ 1 — ติดตั้ง Jenkins

```bash
brew install jenkins-lts
brew services start jenkins-lts
```

เปิดเบราว์เซอร์ไปที่ **http://localhost:8080** จะเจอหน้า "Unlock Jenkins"
ให้เอา initial password มาจากไฟล์ที่หน้าเว็บระบุ (ปกติคือ
`~/.jenkins/secrets/initialAdminPassword`):

```bash
cat ~/.jenkins/secrets/initialAdminPassword
```

จากนั้นเลือก **Install suggested plugins** → รอติดตั้ง → สร้าง admin user

### ขั้นที่ 2 — ติดตั้ง plugins ที่ต้องใช้

`Manage Jenkins → Plugins → Available` แล้วติดตั้ง:

- **Pipeline** (มักติดมาแล้ว)
- **Git**
- **Credentials Binding**
- **JUnit** (ใช้เมื่อเปิด stage Unit tests)
- **Coverage** (ใช้เมื่อเปิด stage Coverage report — แสดง tab coverage จาก Cobertura XML ที่ `fastlane test` สร้าง)
- **GitHub** (ถ้าจะใช้ webhook ให้ push แล้วรันเอง)

### ขั้นที่ 3 — ตั้ง label `macos` ให้ node

`Manage Jenkins → Nodes → Built-In Node → Configure → Labels` ใส่ `macos`
(Jenkinsfile ใช้ `agent { label 'macos' }`)

> Jenkins ที่เริ่มด้วย `brew services` จะรันในนาม user ของคุณ จึงเข้าถึง Xcode ได้อยู่แล้ว
> แต่ **Simulator ต้องมี session ล็อกอิน GUI** (เครื่องต้องล็อกอินค้างไว้ ไม่ใช่ SSH เปล่า ๆ) — ข้อนี้ใช้เมื่อเปิด stage Unit tests กลับมาเท่านั้น; stage ที่รันอยู่ตอนนี้ (archive + pilot) ไม่เปิด Simulator

### ขั้นที่ 4 — สร้าง App Store Connect API Key

1. ไปที่ App Store Connect → **Users and Access → Integrations → App Store Connect API**
2. สร้าง key ชนิด **App Manager** แล้วดาวน์โหลดไฟล์ `.p8` (โหลดได้ครั้งเดียว)
3. จดค่า **Key ID** และ **Issuer ID**

### ขั้นที่ 5 — เพิ่ม Credentials ใน Jenkins

`Manage Jenkins → Credentials → System → Global credentials → Add Credentials`

| ID | ชนิด | ค่า |
| --- | --- | --- |
| `asc-api-key` | Secret file | ไฟล์ `AuthKey_XXXXXXXXXX.p8` |
| `asc-key-id` | Secret text | Key ID |
| `asc-issuer-id` | Secret text | Issuer ID |
| `jfrog-sdk-swift-token` | Secret text | access token ของ JFrog Swift package registry (ใช้ใน stage Resolve Swift packages และ Deploy) |

package `poc-sdk.waypointsdk` อยู่ใน registry ส่วนตัวของ JFrog stage Resolve Swift packages
จึงรัน `swift package-registry login` ด้วย token นี้ก่อน `xcodebuild -resolvePackageDependencies`

ถ้า repo เป็น private ให้เพิ่ม credential สำหรับ Git ด้วย (SSH key หรือ GitHub token)
ชื่ออะไรก็ได้ เช่น `github-ssh`

### ขั้นที่ 6 — สร้าง Pipeline job

1. **New Item** → ชื่อ `Marauders-iOS` → เลือก **Pipeline** → OK
2. **Build Triggers** (ถ้าต้องการ auto) → ติ๊ก *GitHub hook trigger for GITScm polling*
   (ตั้งที่ job ไม่ใช่ใน `Jenkinsfile`)
3. เลื่อนลง **Pipeline**:
   - **Definition**: `Pipeline script from SCM`
   - **SCM**: `Git`
   - **Repository URL**: `git@github.com:SomsakGitHub/Marauders.git` (หรือ HTTPS)
   - **Credentials**: `github-ssh` (ถ้า private)
   - **Branch Specifier**: `*/main`
   - **Script Path**: `Jenkinsfile`  ← ไฟล์อยู่ root ของ repo จึงใช้ค่า default ได้เลย
4. **Save**

### ขั้นที่ 7 — รัน build แรก

กด **Build Now** → เปิด **Console Output** ควรมองเห็น:

```
Obtained Jenkinsfile from git ...
[Pipeline] stage (Checkout | Install dependencies | Resolve Swift packages | Deploy to TestFlight)
```

ถ้าผ่านบน `main` build จะถูกอัปโหลดขึ้น TestFlight และได้ `.ipa` เป็น artifact
(JUnit trend และ **Coverage** tab จะมีก็ต่อเมื่อเปิด stage Unit tests / Coverage report กลับมา)

### ขั้นที่ 8 — ให้ push แล้วรันเอง (webhook) — ไม่บังคับ

GitHub ต้องเข้าถึง Jenkins ได้ ถ้า Jenkins อยู่ในเครื่อง (localhost) ต้องเปิด tunnel:

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:8080   # จะได้ URL ชั่วคราว เช่น https://xxxx.trycloudflare.com
```

แล้วไปที่ GitHub repo → **Settings → Webhooks → Add webhook**:

- **Payload URL**: `https://xxxx.trycloudflare.com/github-webhook/`
- **Content type**: `application/json`
- **Events**: `Just the push event`

### ขั้นที่ 9 — ขึ้น TestFlight

เมื่อ build บน `main` pipeline จะเข้า stage **Deploy to TestFlight**:
- `fastlane beta` เรียก lane `build` (gym, Release, export `app-store`) แล้ว `pilot`
  อัปโหลดด้วย App Store Connect API key (`skip_waiting_for_build_processing: true`,
  `distribute_external: false` — ไม่รอ processing และไม่แจกกลุ่มภายนอก)
- build number เพิ่มอัตโนมัติจาก `BUILD_NUMBER` ของ Jenkins

รอสักครู่ build จะโผล่ใน **App Store Connect → TestFlight**

---

## Code signing

โปรเจคตั้ง `CODE_SIGN_STYLE = Automatic` + `DEVELOPMENT_TEAM = 9U8PYJFN94`
lane `build` ส่ง `-allowProvisioningUpdates` พร้อม API key (ถ้าตั้ง `ASC_*` ครบ) ให้ xcodebuild
สร้าง/อัปเดต provisioning profile เอง จึงไม่ต้องเก็บ certificate ใน repo

## Version / Build number

lane `build` อ่าน env `BUILD_NUMBER` (Jenkins ตั้งให้) → ส่ง `CURRENT_PROJECT_VERSION` ตอน archive
ดังนั้น TestFlight build จะเพิ่มขึ้นอัตโนมัติทุกรอบ (ไม่ต้องแก้โปรเจค)

## รันในเครื่อง (local)

```bash
cd Marauders-ios

# unit test + coverage (CI ไม่รันแล้ว — รันเองที่นี่; ต้องมี xcbeautify + xcresultparser)
bundle install
SIMULATOR_DESTINATION="platform=iOS Simulator,name=iPhone 17" bundle exec fastlane test

# ดู coverage ของ target Marauders
xcrun xccov view --report build/test/Marauders.xcresult

# build + อัปโหลด TestFlight (ต้องมี env ASC_*; และต้อง `swift package-registry login`
# ด้วย token JFrog ครั้งเดียวก่อน เพราะ CI ทำขั้นนี้ใน stage Resolve Swift packages แต่ในเครื่องไม่มี)
export ASC_KEY_ID="XXXXXXXXXX"
export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export ASC_KEY_PATH="/path/to/AuthKey_XXXXXXXXXX.p8"
export BUILD_NUMBER=1
bundle exec fastlane beta
```

## Troubleshooting

- **`No profiles for 'com.somsak.Marauders' were found`** → ตรวจว่า API key มีสิทธิ์ App Manager และ `ASC_*` ถูกส่งเข้า xcodebuild
- **`Scheme 'Marauders' not found`** → ตรวจว่า commit `Marauders.xcscheme` (shared) แล้ว
- **`Simulator device failed to launch … Busy/preflight`** → simulator ตอน cold boot ถี่เกินไป (เกิดตอนรัน `fastlane test`; stage Unit tests ที่ปิดอยู่มี `retry(2)`); ถ้าซ้ำให้รัน `xcrun simctl shutdown all`
- **Resolve Swift packages ล้ม / หา `poc-sdk.waypointsdk` ไม่เจอ** → ตรวจ credential `jfrog-sdk-swift-token` ว่ายังไม่หมดอายุ
- **`Command not found: bundle` / Ruby เก่าเกิน** → ตั้ง `PATH` ให้ใช้ Homebrew Ruby (ขั้นที่ 0)
- **simulator ไม่เจอ** → ตั้ง env `SIMULATOR_DESTINATION` ให้ตรงกับ runtime บน agent (เช่น `name=iPhone 16`)
- **เทสต์ผ่านในเครื่องแต่ fail บน CI** → (เมื่อเปิด stage Unit tests กลับมา) ดู `build/test/junit.xml` ใน Jenkins ผ่าน JUnit report
- **JUnit จำนวนเทสต์ไม่ตรง** → ใช้ `xcresultparser` (ไม่ใช้ JUnit ของ xcbeautify) เพราะ Swift Testing นับคลาดเคลื่อน
- **webhook ไม่ยิง** → GitHub ต้องเข้าถึง Jenkins ได้ (ใช้ tunnel ถ้าเป็น localhost) และ Jenkins ต้องเปิด *GitHub hook trigger*

---

## Backend (Cloudflare Worker) — ไม่ได้อยู่ใน CI

Jenkins ดูแลเฉพาะแอป iOS. Worker (`backend/`) **deploy ด้วยมือ** ด้วย `npm run deploy`
(`wrangler deploy`) และ migration ก็รันเอง (`npm run db:migrate`) — ไม่มี stage ใน
`Jenkinsfile` ที่แตะ backend

- **ลำดับ:** รัน migration ก่อน แล้วค่อย deploy Worker ที่ต้องใช้ schema ใหม่
- `db:migrate` อ่าน `DATABASE_URL` จาก `backend/.dev.vars` (gitignored, ดู `backend/.env.example`) ไม่ใช่จาก `wrangler secret`; ถ้าไม่มีบรรทัดนี้จะ error ตั้งแต่ครั้งแรก
- `db:migrate` รัน `backend/sql/` ตั้งแต่ 001 ถึง 017 ยกเว้น `004_purge_feed_videos.sql`
  (purge — รันเองด้วยมือเท่านั้น); รายการไฟล์เป็น array ที่เขียนตายตัวใน
  `scripts/migrate.mjs` ไฟล์ใหม่ เช่น `018_*.sql` จะไม่ถูกรันจนกว่าจะเพิ่มชื่อลงใน array นั้น
- secrets ตั้งด้วย `wrangler secret put`: `DATABASE_URL`, `JWT_SIGNING_SECRET`,
  `APPLE_CLIENT_ID` และ `DEV_LOGIN_SECRET` (optional)
- เทสต์ backend: `npm run typecheck` (`tsc --noEmit`), `npm run test:feed`,
  `npm run test:dubbed-audio`, `npm run test:dev-auth`, `npm run test:comments` (ทั้งหมดเป็น node script) และมี `node scripts/test-audio-assessment.mjs` กับ
  `node scripts/test-upload.mjs` ที่ไม่มี npm script (`test-upload.mjs` ยิง endpoint workers.dev จริง ไม่ใช่เทสต์ในเครื่อง)
- bindings ใน `wrangler.toml`: R2 `VIDEOS` → bucket `marauders-videos` (prefix `videos/`, `avatars/`, `translations/`) และ rate limit `RATE_LIMITER`, `AUTH_RATE_LIMITER`

รายละเอียด: [../deployment/README.md](../deployment/README.md),
[../deployment/AI_DUBBING.md](../deployment/AI_DUBBING.md), [../README.md](../README.md)
