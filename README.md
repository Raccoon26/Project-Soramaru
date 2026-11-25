# Project-Soramaru

일본어 팬 커뮤니티 앱 「ぐーもるそらまる」의 공개 소스 저장소입니다. 현재 로컬에서 일본어 테스트 앱과 Workers API 상태 확인을 실행할 수 있습니다. 정식 명칭·콘텐츠·권한은 출시 전 별도 확인합니다.

## 로컬 실행

Node.js 24.x, Flutter 3.50.1/Dart 3.14, Android 빌드는 JDK 21과 SDK 36(빌드 도구 36.0.0, NDK 28.2.13676358). Windows 프로젝트 SDK·캐시는 E:의 `.local/` 경로를 사용합니다. SDK 경로/캐시 변수를 로컬 터미널 세션에 지정하고 기존 시스템 설정은 유지합니다. 아래 예시는 SDK 설치가 끝난 별도 PowerShell에서 실행합니다.

```powershell
Set-Location E:\Project-Soramaru
$project = (Get-Location).Path
New-Item -ItemType Directory -Force .local/tmp,.local/appdata,.local/android-user | Out-Null
$env:TEMP = "$project/.local/tmp"
$env:TMP = $env:TEMP
$env:APPDATA = "$project/.local/appdata"
$env:LOCALAPPDATA = $env:APPDATA
$env:XDG_CONFIG_HOME = "$project/.local/flutter-config"
$env:npm_config_cache = "$project/.local/npm-cache"
$env:CLOUDFLARE_SEND_METRICS = 'false'
$env:PUB_CACHE = "$project/.local/pub-cache"
$env:ANDROID_HOME = "$project/.local/sdk/android"
$env:ANDROID_USER_HOME = "$project/.local/android-user"
$env:ANDROID_AVD_HOME = "$project/.local/android-user/avd"
$env:GRADLE_USER_HOME = "$project/.local/gradle"
$env:JAVA_TOOL_OPTIONS = "-Duser.home=$env:ANDROID_USER_HOME"
$flutter = "$project/.local/sdk/flutter/bin/flutter.bat"

npm ci --ignore-scripts --no-audit --no-fund
npm run check:repo
npm run lint
npm test
npm run build:api
npm run db:migrate
npm run dev:api
```

API가 뜬 뒤 별도 PowerShell에서 `Invoke-RestMethod http://127.0.0.1:8787/v1/health`를 실행하면 `status = ok`를 반환합니다. DEV-00은 외부 계정이나 환경 변수 없이 작동합니다. 서비스 환경 값 예시는 `services/api/.env.example`에 있습니다.

SDK가 준비된 첫 번째 터미널에서 `JAVA_HOME`을 설치한 JDK 21의 경로로 지정한 뒤 아래를 실행합니다.

```powershell
Set-Location "$project/apps/mobile"
& $flutter --suppress-analytics pub get --enforce-lockfile
& $flutter --suppress-analytics analyze --no-pub
& $flutter --suppress-analytics test --no-pub
& $flutter --suppress-analytics build apk --debug --no-pub --target-platform android-arm64
& $flutter --suppress-analytics run
```

APK는 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`에 생성됩니다. `run`에는 실제 Android 기기나 에뮬레이터가 필요합니다. iOS 확인에는 Mac/Xcode가 필요합니다. [Flutter SDK](https://docs.flutter.dev/release/archive) · [Android SDK 관리자](https://developer.android.com/tools/sdkmanager) · [iOS 설정](https://docs.flutter.dev/platform-integration/ios/setup)

## 문서

- 이어서 작업할 단계, 잔여 검증 및 현재 CI는 [프로젝트 상태](PROJECT_STATUS.md), [테스트 보고](TEST_REPORT.md)에 기록합니다.
- [마스터 요구사항](MASTER_REQUIREMENTS.md), [추적표](REQUIREMENTS_MATRIX.md), [DEV 로드맵](DEV_ROADMAP.md)
- [UI 실측](UI_REFERENCE.md), [화면 인벤토리](SCREEN_INVENTORY.md), [디자인 시스템](DESIGN_SYSTEM.md)
- [아키텍처](ARCHITECTURE.md), [API](API_DESIGN.md), [데이터베이스](DATABASE_DESIGN.md)
- [비용](COST_POLICY.md), [보안](SECURITY_POLICY.md), [운영](OPERATION_GUIDE.md), [콘텐츠](CONTENT_GUIDE.md), [권리](RIGHTS_STATUS.md), [출시 점검](RELEASE_CHECKLIST.md)
- [개발 규칙](AGENTS.md)과 로컬 `references/` 격리 규칙을 적용합니다.

## DEV-02 탐색과 개발용 프리뷰

디버그 기본 시작은 다섯 하단 탭의 DEV-02 내비게이션입니다. `その他 → 画面状態と操作`에서 공용 상태를 볼 수 있습니다. `--dart-define=DEV_LEGACY_PREVIEW=true`로 DEV-01 모드, `--dart-define=DEV_PREVIEW=false`로 개발 진입을 끈 상태를 실행합니다. 릴리스는 플래그 값에 관계없이 개발용 로그인·합성 경로를 차단하고 대기 화면을 엽니다. [라우트와 복원 정책](NAVIGATION_GUIDE.md)

앱 경로에서 `flutter test --no-pub`로 계정·5탭·링크·복원·접근성·Golden을 검사합니다. 아래 옵션은 대표 화면을 프로젝트의 `.local/dev-02-preview/`에 저장합니다.

```powershell
& $flutter test --no-pub test/navigation_layout_test.dart --dart-define=CAPTURE_DEV02=true
```

DEV-01 캡처는 `flutter test test/preview_golden_test.dart --dart-define=CAPTURE_DEV01=true`로 생성합니다. 기존 Golden은 Windows와 Linux에서 운영체제별 합성 기준을 사용합니다. [디자인 시스템](DESIGN_SYSTEM.md) · [검증 기록](TEST_REPORT.md)

## DEV-03 로컬 서버와 모바일 연결 확인

`npm run db:migrate` 뒤 `npm run smoke:api`로 실제 로컬 workerd가 D1 준비 상태에 도달하는지 검사합니다. `npm run dev:api`를 중지할 때는 Ctrl+C를 사용합니다. 데이터 초기화, 백업과 복원 절차는 각 안내를 참조합니다. [서버 안내](BACKEND_GUIDE.md) · [마이그레이션](DATABASE_MIGRATION_GUIDE.md) · [비용 제어](COST_CONTROL_GUIDE.md) · [백업과 복구](BACKUP_RESTORE_GUIDE.md)

Android 에뮬레이터에서는 `flutter run --dart-define=DEV_API_ORIGIN=http://10.0.2.2:8787`로 `その他`의 개발용 연결 확인을 활성화할 수 있습니다. 실제 로컬 USB 기기는 프로젝트 외 규칙을 바꾸지 않고 필요한 개발 연결 경로를 준비한 뒤 접근합니다. 서버는 사용자가 연결 확인을 눌렀을 때만 호출됩니다.

## DEV-04 개발용 회원 연결

별도 터미널에서 `npm run auth:emulator`와 `npm run auth:worker`를 실행하고 Flutter에 `--dart-define=DEV_MEMBERSHIP=true`를 지정합니다. Emulator CLI 설치·D1 마이그레이션·테스트·종료 절차는 가이드를 참조합니다. [Firebase 개발 가이드](FIREBASE_EMULATOR_GUIDE.md) · [인증 가이드](AUTHENTICATION_GUIDE.md) · [세션 관리](SESSION_MANAGEMENT_GUIDE.md) · [회원 수명](MEMBER_LIFECYCLE_GUIDE.md)

## DEV-05 팬 게시판

팬 게시판 개발 및 검증은 [팬 게시판 가이드](FAN_COMMUNITY_GUIDE.md), [게시물 수명](POST_LIFECYCLE_GUIDE.md), [기기 임시 글](LOCAL_DRAFT_GUIDE.md), [신고·차단](MODERATION_GUIDE.md)을 사용한다.


## DEV-06 사진 개발

[사진 업로드](MEDIA_UPLOAD_GUIDE.md) · [이미지 처리](IMAGE_PROCESSING_GUIDE.md) · [사진 권한](MEDIA_ACCESS_GUIDE.md) · [GALLERY](GALLERY_GUIDE.md) · [수명주기와 저장 비용](MEDIA_LIFECYCLE_GUIDE.md)

로컬에서 `npm run db:migrate`, `node tools/photo-fixtures.mjs`를 실행하고 개발용 Firebase Auth Emulator와 Worker에 연결한다. 도구와 합성 데이터만으로 검증하며 운영 계정·버킷 또는 결제 활성화 승인이 별도로 필요하다.
