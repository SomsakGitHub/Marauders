# CI/CD — iOS (Jenkins → TestFlight)

Pipeline นี้รันบน **Jenkins (macOS)** ทำหน้าที่ build, รัน unit test แล้วอัปโหลดขึ้น
**TestFlight** เมื่อ push เข้า `main`

## ภาพรวม flow

```
push/PR ─▶ Checkout ─▶ bundle install ─▶ Unit tests (MaraudersTests) ─▶ [main] Archive ─▶ TestFlight
```

## ไฟล์ที่เกี่ยวข้อง

| ไฟล์ | หน้าที่ |
| --- | --- |
| `Jenkinsfile` | ประกาศ pipeline (stages, credentials, artifacts) |
| `Marauders-ios/Gemfile` | pin `fastlane` ให้ Jenkins ใช้เวอร์ชันเดียวกัน |
| `Marauders-ios/fastlane/Appfile` | `app_identifier` + `team_id` |
| `Marauders-ios/fastlane/Fastfile` | lane `test` และ `beta` (archive + upload) |
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
- **JUnit**
- **GitHub** (ถ้าจะใช้ webhook ให้ push แล้วรันเอง)

### ขั้นที่ 3 — ตั้ง label `macos` ให้ node

`Manage Jenkins → Nodes → Built-In Node → Configure → Labels` ใส่ `macos`
(Jenkinsfile ใช้ `agent { label 'macos' }`)

> Jenkins ที่เริ่มด้วย `brew services` จะรันในนาม user ของคุณ จึงเข้าถึง Xcode ได้อยู่แล้ว
> แต่ **Simulator ต้องมี session ล็อกอิน GUI** — เครื่องต้องล็อกอินค้างไว้ ไม่ใช่ SSH เปล่า ๆ

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

ถ้า repo เป็น private ให้เพิ่ม credential สำหรับ Git ด้วย (SSH key หรือ GitHub token)
ชื่ออะไรก็ได้ เช่น `github-ssh`

### ขั้นที่ 6 — สร้าง Pipeline job

1. **New Item** → ชื่อ `Marauders-iOS` → เลือก **Pipeline** → OK
2. **Build Triggers** (ถ้าต้องการ auto) → ติ๊ก *GitHub hook trigger for GITScm polling*
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
[Pipeline] stage (Checkout | Install dependencies | Unit tests | ...)
```

ถ้าผ่าน จะได้ JUnit trend (70 tests) + coverage ในหน้า build

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

เมื่อ push เข้า `main` pipeline จะเข้า stage **Deploy to TestFlight**:
- `fastlane beta` จะ archive (Release) แล้วอัปโหลดด้วย App Store Connect API key
- build number เพิ่มอัตโนมัติจาก `BUILD_NUMBER` ของ Jenkins

รอสักครู่ build จะโผล่ใน **App Store Connect → TestFlight**

---

## Code signing

โปรเจคตั้ง `CODE_SIGN_STYLE = Automatic` + `DEVELOPMENT_TEAM = 9U8PYJFN94`
lane `beta` ส่ง `-allowProvisioningUpdates` พร้อม API key ให้ xcodebuild
สร้าง/อัปเดต provisioning profile เอง จึงไม่ต้องเก็บ certificate ใน repo

## Version / Build number

`Jenkinsfile` ส่ง `BUILD_NUMBER` → ตั้ง `CURRENT_PROJECT_VERSION` ตอน archive
ดังนั้น TestFlight build จะเพิ่มขึ้นอัตโนมัติทุกรอบ (ไม่ต้องแก้โปรเจค)

## รันในเครื่อง (local)

```bash
cd Marauders-ios

# unit test + coverage (ต้องมี xcbeautify + xcresultparser ในเครื่อง)
bundle install
SIMULATOR_DESTINATION="platform=iOS Simulator,name=iPhone 17" bundle exec fastlane test

# ดู coverage ของ target Marauders
xcrun xccov view --report build/test/Marauders.xcresult

# build + อัปโหลด TestFlight (ต้องมี env ASC_*)
export ASC_KEY_ID="XXXXXXXXXX"
export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export ASC_KEY_PATH="/path/to/AuthKey_XXXXXXXXXX.p8"
export BUILD_NUMBER=1
bundle exec fastlane beta
```

## Troubleshooting

- **`No profiles for 'com.somsak.Marauders' were found`** → ตรวจว่า API key มีสิทธิ์ App Manager และ `ASC_*` ถูกส่งเข้า xcodebuild
- **`Scheme 'Marauders' not found`** → ตรวจว่า commit `Marauders.xcscheme` (shared) แล้ว
- **`Simulator device failed to launch … Busy/preflight`** → simulator ตอน cold boot ถี่เกินไป pipeline มี `retry(2)` ให้แล้ว; ถ้าซ้ำให้รัน `xcrun simctl shutdown all` บน agent
- **`Command not found: bundle` / Ruby เก่าเกิน** → ตั้ง `PATH` ให้ใช้ Homebrew Ruby (ขั้นที่ 0)
- **simulator ไม่เจอ** → ตั้ง env `SIMULATOR_DESTINATION` ให้ตรงกับ runtime บน agent (เช่น `name=iPhone 16`)
- **เทสต์ผ่านในเครื่องแต่ fail บน CI** → ดู `build/test/junit.xml` ใน Jenkins (แชร์ผ่าน JUnit report)
- **JUnit จำนวนเทสต์ไม่ตรง** → ใช้ `xcresultparser` (ไม่ใช้ JUnit ของ xcbeautify) เพราะ Swift Testing นับคลาดเคลื่อน
- **webhook ไม่ยิง** → GitHub ต้องเข้าถึง Jenkins ได้ (ใช้ tunnel ถ้าเป็น localhost) และ Jenkins ต้องเปิด *GitHub hook trigger*
