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
| `Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders Production.xcscheme` | shared scheme ของ build Production (configuration `Release-Production`, ไม่มี test target) — Jenkins กับ lane `build` ใช้ตัวนี้ส่ง TestFlight (จำเป็นสำหรับ clean checkout) |
| `Marauders-ios/Marauders.xcodeproj/xcshareddata/xcschemes/Marauders Staging.xcscheme` | shared scheme ของ build Staging (configuration `Debug-Staging`, มี `MaraudersTests` กับ `MaraudersUITests`) — ใช้รันจาก Xcode และ lane `test` |

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
- `fastlane beta` เรียก lane `build` (gym, scheme `Marauders Production`, configuration `Release-Production`, export `app-store`) แล้ว `pilot`
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
- **`Scheme 'Marauders Production' not found`** (หรือ `'Marauders Staging'`) → ตรวจว่า commit `Marauders Production.xcscheme` และ `Marauders Staging.xcscheme` (shared) แล้ว ชื่อ scheme เดิม `Marauders` ไม่มีอีกแล้ว
- **`Simulator device failed to launch … Busy/preflight`** → simulator ตอน cold boot ถี่เกินไป (เกิดตอนรัน `fastlane test`; stage Unit tests ที่ปิดอยู่มี `retry(2)`); ถ้าซ้ำให้รัน `xcrun simctl shutdown all`
- **Resolve Swift packages ล้ม / หา `poc-sdk.waypointsdk` ไม่เจอ** → ตรวจ credential `jfrog-sdk-swift-token` ว่ายังไม่หมดอายุ
- **`Command not found: bundle` / Ruby เก่าเกิน** → ตั้ง `PATH` ให้ใช้ Homebrew Ruby (ขั้นที่ 0)
- **simulator ไม่เจอ** → ตั้ง env `SIMULATOR_DESTINATION` ให้ตรงกับ runtime บน agent (เช่น `name=iPhone 16`)
- **เทสต์ผ่านในเครื่องแต่ fail บน CI** → (เมื่อเปิด stage Unit tests กลับมา) ดู `build/test/junit.xml` ใน Jenkins ผ่าน JUnit report
- **JUnit จำนวนเทสต์ไม่ตรง** → ใช้ `xcresultparser` (ไม่ใช้ JUnit ของ xcbeautify) เพราะ Swift Testing นับคลาดเคลื่อน
- **webhook ไม่ยิง** → GitHub ต้องเข้าถึง Jenkins ได้ (ใช้ tunnel ถ้าเป็น localhost) และ Jenkins ต้องเปิด *GitHub hook trigger*

---

## Backend (Cloudflare Worker) — CI รันเทสต์ออฟไลน์ ส่วน deploy คือ script ที่คุมไว้

Jenkins ดูแลเฉพาะแอป iOS — ไม่มี stage ใน `Jenkinsfile` ที่แตะ backend ส่วน backend (`backend/`) มีสองเรื่องแยกกัน:

**1. CI รันเทสต์เท่านั้น** — GitHub Actions workflow `.github/workflows/backend.yml` (job `test` บน `ubuntu-latest`) รัน `npm ci` แล้ว `npm test` ใน `backend/` เมื่อ push เข้า `main`, เมื่อมี pull request และสั่งมือได้ (`workflow_dispatch`) เฉพาะเมื่อไฟล์ที่เกี่ยวข้องเปลี่ยน (`backend/**`, ตัว workflow เอง, และไฟล์ iOS ที่เทสต์ความตรงกันของ URL อ่าน: `project.pbxproj`, `Config/Info-Additions.plist`, `APIConfiguration.plist`)

- `npm test` = `tsc --noEmit` + เทสต์ของ script และ guard ของ environment (`test:scripts`) + `/health` + เทสต์ของ route ทั้งหมด — ทั้งหมดออฟไลน์ (database เป็นของปลอมในเครื่อง) จึง**ไม่ต้องมี secret ใด ๆ**
- workflow ตั้ง `permissions: contents: read`, ยกเลิกรอบเก่าที่ซ้อนกัน (`concurrency`), ไม่ใช้ `pull_request_target`, และ pin ทุก action ด้วย commit SHA
- **ไม่มี deploy และไม่มีการ migrate ใน CI โดยเจตนา:** repo นี้เป็น public และ Cloudflare API token ที่ใช้ deploy ได้เท่าที่ทราบจำกัดให้ Worker เดียวไม่ได้ (ต้องเก็บไว้ใน settings ของ GitHub พร้อม `DATABASE_URL` ของ production) การ deploy จึงเป็น script ที่เจ้าของโปรเจกต์รันจากเครื่องตัวเอง — เหตุผลและทางเลือกอื่นอยู่ใน [ADR-010](./adr/010-environments.md) (ถ้าภายหลังอยากให้ CI deploy staging ได้โดยไม่ต้องออกแบบใหม่: workflow เรียก script เดียวกัน)

**2. Deploy คือ script ที่ระบุ environment เสมอ** — `npm run deploy:production` (ใน `backend/`; `npm run deploy:staging` ใช้ได้หลังสร้าง staging ซึ่งตอนนี้ยังไม่มี) ทำตามลำดับ: เช็ก login Cloudflare (`wrangler whoami`) → เทสต์ทั้งชุด → แผน migration (dry run) → phrase ยืนยัน (production) → migration → `wrangler deploy --env <env>` → ตรวจ `<url>/health` ว่าเป็น environment และเวอร์ชันที่เพิ่ง deploy → พิมพ์คำสั่ง rollback รายละเอียดทุกขั้น เหตุผลของลำดับ และ rollback อยู่ใน [../deployment/README.md](../deployment/README.md)

- migration ติดตามในตาราง `schema_migrations` ของแต่ละ database: `npm run db:migrate -- --env <staging|production> [--dry-run]` รันเฉพาะไฟล์ใหม่ตามเลข (ไม่รัน `004_purge_feed_videos.sql`) และหยุดถ้าไฟล์ที่รันไปแล้วถูกแก้ (`--accept-changed <ไฟล์>`); ไฟล์ SQL ต้องรันซ้ำได้และไม่มี `;` ในคอมเมนต์
- ทุกคำสั่งที่แตะข้อมูลมี `--env` และไม่มีค่า default; เขียนลง production ต้องพิมพ์ phrase ยืนยัน; **ห้ามรัน `wrangler deploy` เปล่า ๆ** (ชี้ production)
- secrets ตั้งแยกต่อ Worker ด้วย `wrangler secret` (`DATABASE_URL`, `JWT_SIGNING_SECRET`, `APPLE_CLIENT_ID`; `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` ใช้เฉพาะตอนลบบัญชีและไม่บังคับ — ไม่ตั้งแล้วบัญชี Apple ลบไม่ได้ (`503`) วิธีสร้างกุญแจและลำดับขึ้นระบบอยู่ใน [deployment/README.md](../deployment/README.md) หัวข้อ "ลบบัญชี"; `DEV_LOGIN_SECRET` ตอนนี้อยู่ที่ production เพราะมี backend ตัวเดียว เมื่อสร้าง staging แล้วเฉพาะ staging — production ต้องไม่มี); ไฟล์ vars ในเครื่องคือ `backend/.dev.vars.staging` / `.dev.vars.production` (ดู `backend/.dev.vars.example`)
- bindings ใน `wrangler.toml`: R2 `VIDEOS` → `marauders-videos` (production) / `marauders-videos-staging` (prefix `videos/`, `avatars/`, `translations/`) และ rate limit `RATE_LIMITER`, `AUTH_RATE_LIMITER` — `[env.staging]` เขียนซ้ำทั้งหมด เพราะ wrangler environment ไม่สืบทอดอะไรจากระดับบน และเทสต์ `parity` จะล้มถ้าสองฝั่งไม่ตรงกัน
- **ฝั่งแอป:** แอปมีสอง build บน backend production ตัวเดียวกัน (เพราะมี backend ตัวเดียว): **Staging** (scheme `Marauders Staging`, configuration `Debug-Staging`, รันจาก Xcode, มีแท็บ Log ในแอปและ dev login) กับ **Production** (scheme `Marauders Production`, configuration `Release-Production`, ที่ Jenkins ใช้ส่ง TestFlight) build Production มี Run Script phase `Run Script release config check` ที่ทำให้ build ล้มถ้า URL ในแอปไม่ใช่ของ production ใน `backend/environments.json` หรือถ้า executable มี type ที่ใช้เฉพาะ Debug (`DebugLogView` = แท็บ Log ในแอป, `DevAuthAPIClient` = dev login) — build ที่ชี้ผิดที่หรือมี log ในแอปจึงอัปโหลดขึ้น TestFlight ไม่ได้ (build Staging ข้าม phase นี้)

รายละเอียด: [../deployment/README.md](../deployment/README.md),
[../deployment/AI_DUBBING.md](../deployment/AI_DUBBING.md), [../README.md](../README.md), [ADR-010](./adr/010-environments.md)
