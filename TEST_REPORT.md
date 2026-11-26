# 테스트 보고

## 2026-11-24 DEV-00

| 검사 | 결과 | 근거 |
|---|---|---|
| 원본 이미지 | 통과 | JPEG 51/PNG 2 이미지 검증/디코드 및 화면별 분석. SHA-256 동일 파일 0. 근접 이미지 같은 화면 유형 대조. |
| 원본 영상 | 통과 | FFprobe 305.535초, FFmpeg H.264/AAC 전체 디코드와 프레임 추출 1,528개, 표본 및 전환 검토. |
| 원본 SHA-256 | 통과 | 시작 시 기록한 54건의 파일명·바이트·해시와 작업 후 동일. |
| 민감 참조 검사 | 통과 | 화면·메타데이터에서 확인한 유형만 정리. 개발/테스트 데이터는 합성. |
| Flutter 분석·위젯 | 통과 | Flutter 3.50.1/Dart 3.14, analyzer 0건, 일본어 시작 테스트 1건. |
| Flutter 번들 | 통과 | `flutter build bundle --no-pub`, `apps/mobile/build/flutter_assets/`. |
| Android ARM64 | 통과 | JDK 21 / SDK·대상 36, `flutter build apk --debug --no-pub --target-platform android-arm64`. `aapt dump badging`에서 min 24, 패키지/일본어 표시 및 arm64-v8a 확인. `apksigner verify` 성공. |
| iOS | 미검증 | Windows 환경에서 Xcode 빌드 불가. Mac 시뮬레이터, unsigned 빌드 및 실제 기기 확인이 남음. |
| API 분석·빌드 | 통과 | Node 24.19.0에서 ESLint, TypeScript, Cloudflare Vite 패키징. |
| API 자동 테스트 | 통과 | 3건. GET JSON/헤더, 오류·메서드 계약, localhost 실제 workerd HTTP 응답. |
| 요구사항·문서·Git | 로컬 확인 | `npm run check:repo`로 IDs·화면/권리 참조·19개 문서·원본 제외 경로를 검사. 범위/화면 추적과 §0–17 대조. |
| 보안 | 로컬 확인 | 미디어·환경 파일 스테이징 검사, Gitleaks 및 npm audit, Git에 원본/원본 해시 파일·개인정보 미포함 확인. 후속 보안 구현 및 스토어 심사는 별도 검증. |
| GitHub Actions | PR 기준 | GitHub PR에 연결된 Checks에서 커밋별 결과를 확인. |
| 기기 성능·배터리 | 미검증 | 앱 프리뷰의 기본 분석/빌드만 검증. 기기 및 장시간 작업은 DEV-16/17에서 측정. |

윈도우의 프로젝트 도구·캐시·결과는 E:에 배치했다. 호스트에 설치돼 있던 Git·Node.js·Python·JDK는 실행에 사용했다. 설치 과정에서 Flutter의 최신 Material API로 갱신했으며 `cf build`의 워크스페이스 감지 문제는 같은 Cloudflare 플러그인을 쓰는 Vite 직접 빌드로 해결했다. 운영 계정·인증·미디어·푸시·배포는 이 테스트 범위 밖이다.

## 2026-11-24 공개 전환·PR #1 병합 재검증

- PR 헤드 `57ffe10`에서 `npm run check:repo`, `npm run lint`, `npm test`(3건), `npm run build:api`, actionlint, `npm audit --audit-level=moderate`를 통과했다. npm audit 보고는 0건이다.
- Flutter 잠금 파일, 포맷, 분석, 일문 위젯 테스트 1건, ARM64 디버그 빌드, APK 서명을 Windows에서 재검증했다.
- 공개 브랜치·태그·PR Git 참조에서 도달하는 4개 커밋, 고유 blob 104개와 원본 SHA-256 54건을 검사했다. Gitleaks와 개인정보 패턴 점검에서 미해결 항목은 0건이다. 19개 고유 바이너리 blob은 Flutter SDK 기본 이미지와 일치했다. GitHub Actions 아티팩트와 GitHub 릴리스는 각각 0건이었다.
- 두 원격 CI 작업은 [PR #1 검사](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45394581354)에서 성공했다. 활성 `main` 적용 규칙 및 레거시 보호는 없었다. 검증한 헤드 SHA를 지정해 병합했고 `0f5777b`가 로컬과 원격 `main`에 포함되었음을 확인했다.

## DEV-01 디자인 시스템

- Flutter 3.50.1/Dart: format 및 analyze, 테스트 29건을 검증했다. 기존 DEV-00 일본어 시작 테스트 1건과 DEV-01 Golden 2건이 포함된다. Golden은 OFL 글꼴의 일본어 부분집합과 SDK 아이콘을 고정해 사용한다. Linux와 Windows 렌더를 실제 비교하니 배치와 크기는 같았고 글자·아이콘의 래스터화 차이가 있었다(4.76%, 5.59%). 각 환경에서 별도 기준을 픽셀 단위로 비교하며, 최초 Linux 진단은 합성 캡처 2장만 사용했다.
- 320/390/430/768 논리 px × 100/130/200%의 12조합에서 대표 프리뷰 10개(120개 렌더)를 확인했다. 별도로 가로 회전, 양쪽 안전 여백, 입력·키보드 인셋, 뒤로가기/모달, 안내 배너 아래 기존 데이터 유지, 알림 및 선택 semantics를 검사했다. 목표 대비는 본문 4.5:1, 필수 경계 3:1이다.
- 로컬 캡처를 기존 참조와 대조하고 누락된 테스트 아이콘 폰트, 진하게 표시된 기본 구분선과 회전·키보드 검증의 스크롤 타이밍을 수정했다. 캡처는 `.local/dev-01-preview/`에 저장되며 운영체제별 합성 Golden 각 2장만 Git에 포함한다.
- API lint, 타입 검사, workerd를 포함한 테스트 3건, API 번들, actionlint, npm audit(0건), 요구사항 및 Git 경로 검사 통과. 비교 기준과 제품 기능의 구현 일정은 추적표를 참조한다.
- Windows Flutter 번들과 ARM64 디버그 APK 빌드 및 `apksigner verify`를 통과했다. APK는 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`다.
- Flutter 프리뷰는 네트워크·미디어 디코딩·상태 카탈로그의 지속 애니메이션 없이 동작하도록 구성했다. 피드/알림은 지연 생성, 그림은 고정 도형 및 분리된 페인트 경계를 사용한다. 실제 기기 프레임 시간·배터리·VoiceOver·TalkBack·iOS 빌드는 미측정 또는 미검증이다.
- DEV-00 문서의 4커밋/104 blob은 PR #1 병합 전 원격 감사 범위다. 6커밋/112 blob은 DEV-00 문서 PR #2 병합 후 원격 범위다. 둘 다 도달 가능한 브랜치·태그·PR 기준이고 동일 blob은 중복 집계하지 않았다. DEV-01에서 원본 54건의 SHA-256을 다시 비교했다.

## DEV-02 내비게이션 및 통합 검사

| 검사 | 결과와 근거 |
|---|---|
| Windows Flutter | 잠금 파일 재현, 포맷, 분석 통과. 기존 29건과 신규 45건을 포함한 기본 테스트 74건. DEV-01 Windows Golden 2건은 기존 이미지로 비교했다. Linux는 CI에서 기존 Linux Golden으로 검사한다. |
| 화면과 이동 | 5개 루트·탭별 스택·재선택·스크롤, 작성 텍스트·태그·사진과 확인 대화상자, 헤더·시스템 뒤로 및 바텀 시트, 회원증·사진·플레이어 전체 화면, 콘텐츠·프로필 대표 경로를 테스트했다. 알림 8종의 이동·복귀 및 미읽음 수 유지를 확인했다. |
| 복원과 일본어 | 탭 간 왕복, 백그라운드 복귀, 프로세스 재생성, 계정 변경·만료, 텍스트 복원 제외. 화면 제목·숫자·개수, JST 자정·시간·상대 시간 형식을 검증했다. |
| 접근성 및 레이아웃 | 320/390/430/768dp × 100/130/200%에서 DEV-02 6종(72회)과 DEV-01 10종(120회)을 확인했다. 회전, Safe Area, 키보드 인셋, iOS 전환 유형·제스처 허용 조건, 감소 모션은 위젯 테스트로 검사했다. |
| 링크와 세션 | 허용 유형 9개, 콜드/웜, 로그인 후 복귀, 만료·취소, 없는/삭제/권한 없는 대상, 외부 URL·중복 query·길이·인코딩·공식 경로 차단을 검사했다. |
| Flutter 번들과 Android | Flutter 번들, ARM64 디버그 APK, APK 서명 v2 검증 통과. 패키지 `dev.soramaru.bootstrap`, minSdk 24, targetSdk 36. 두 프리뷰 플래그를 모두 켠 ARM64 릴리스 APK도 빌드해 AOT 페이로드에서 합성 로그인·공식 화면·개발 딥링크의 대표 문자열이 빠지고 대기 화면 문자열이 들어 있음을 확인했다. 연결된 Android 기기가 없어 APK 실행은 미검증이다. |
| API 및 저장소 | ESLint·TypeScript 검사, API 테스트 3건, API 번들, actionlint, `check:repo` 통과. 기존 요구사항 125개, 참조 이미지 기록 53개, 문서 20개. |
| 공개 안전 검사 | 원본 54개 SHA-256 일치. 원격이 광고한 브랜치·태그·PR의 도달 이력과 로컬 이력에서 비밀·개인정보 패턴·보호된 참조 파일을 검사했다. npm audit 0건, Flutter 잠금 파일의 Pub 호스팅 패키지 35개 OSV 조회 0건. |
| CI와 보호 | [DEV-02 PR과 Checks](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-02-navigation)와 [main 실행 기록](https://github.com/Raccoon26/Project-Soramaru/actions/workflows/ci.yml?query=branch%3Amain)에서 원격 증거를 확인한다. |
| 기기 성능·플랫폼 | 피드·알림 지연 렌더와 탭별 지연 진입, 컨트롤러 해제, 세션 세대마다 리스너/라우터 폐기, 전환 중 중복 열기 억제를 코드와 회귀 테스트로 확인했다. 프레임 시간·메모리·배터리, iOS 빌드·실제 제스처, VoiceOver·TalkBack은 미측정 또는 미검증이다. |

회귀 검사에서 웜 링크의 로그인 대기 대상 만료 시 로그인 화면에 남는 문제와 알림 복귀 뒤 대상 탭에 상세가 남는 문제를 발견했다. 세션 전환 처리와 스택 기록 순서를 고쳤으며 동일 목적지가 이미 열린 경우도 테스트했다. 작성 캡처에서 테스트 글꼴에 없던 한자는 DEV-02 전용 OFL 부분집합에 추가했다. 기존 Golden 파일은 유지했다.

`apps/mobile`에서 `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build bundle --no-pub`, `flutter build apk --debug --no-pub --target-platform android-arm64`를 실행한다. `flutter test --no-pub test/navigation_layout_test.dart --dart-define=CAPTURE_DEV02=true`는 585×1230 PNG 12장을 로컬 `.local/dev-02-preview/`에 쓴다. Windows 프로젝트 SDK·캐시·빌드·캡처는 E:를 사용한다. 실제 운영 리소스 생성과 배포 없이 확인했다. [OSV 일괄 조회](https://google.github.io/osv.dev/post-v1-querybatch/)

## DEV-03 로컬 서버 및 통합 검사

| 검사 | 결과와 근거 |
|---|---|
| DEV-00~02 회귀 | 변경 전 Flutter 74건, API 3건을 재현했다. Flutter Golden 기준 및 58경로·5탭·9종 링크를 유지했다. |
| HTTP 및 격리 | Vite/workerd는 빈 Test의 liveness 200·준비 503, 마이그레이션된 Local의 준비 200, 기본 서버의 합성 자격 401을 확인했다. Staging/Production 선택을 차단했다. |
| D1 | 로컬 바인딩에서 SQL 4버전, 35개 테이블. 초기 설치, v1→v4 업그레이드, 반복·경합 적용, 잘못된 SQL 롤백과 재시도 및 체크섬 드리프트를 검사했다. |
| 인덱스·데이터 | 실제 D1에서 피드·작성자·공개시간·댓글·알림·작업 인덱스 EXPLAIN, 읽기 메타, 동시 시각 커서·권한·FK·중복 반응·배지·상태 제약을 검증했다. |
| 비용·레이트 | 모든 비용 항목, UTC 일·월, 70/80/90/95/98%, 플래그, 지표 지연, 헤더 조작 및 동시 다중 요청을 비교했다. 독립 서비스 객체가 공유 로컬 D1에서 한도를 넘지 않았다. 비용 모형은 4 MAU와 9 패턴을 비교한다. |
| R2 및 작업 | 서로 다른 로컬 비공개·격리 버킷에서 용량 경합, 미승인/다른 회원 접근, Range, 해시, 부분 실패 복구와 고아 삭제를 검사했다. 작업 재시도·최대 횟수·임대 만료와 Outbox의 동시 중복 및 원자 롤백을 확인했다. |
| 백업 | AES-GCM·SHA-256, 별도 D1 복원, 스키마/데이터 비교, 손상·낡은 삭제 일지 거절 및 삭제 재적용. |
| 모바일 | DEV-03 API 테스트 8건 추가, 기존 74건 포함 Windows Flutter 82건. API 매핑·시간 제한·재시도·오래된 응답·개발 연결 화면을 검사했다. Flutter 포맷·분석·번들과 ARM64 디버그 APK·서명을 확인했다. 개발 플래그를 지정한 ARM64 릴리스의 매니페스트와 AOT에서 평문·개발 환경 격리도 확인했다. |
| API/저장소 | TypeScript, ESLint, 로컬 테스트 26건(기존 3건, 신규 23건), Vite 번들·check:repo·actionlint 및 잠금 의존성 점검. 공개 Git·스테이징과 원본 54개 SHA-256을 확인한다. |
| 실제 운영·기기 | Cloudflare 운영 CPU·청구량, iOS 빌드, Android/iOS 실기기 및 기기 성능은 미검증이다. 로컬 D1 메타와 모형은 공급자 청구를 직접 측정하지 않는다. |

기존 Miniflare v5가 v4 개별 저장 경로 옵션을 사용하지 않아 초기 Vite와 CLI가 서로 다른 DB를 읽었다. 공유 `v3` 경로를 사용하도록 수정하고 준비 검사를 CI에 추가했다. Node의 타입 제거 모드와 호환되는 TypeScript 문법으로 교정했다. Android 네트워크 XML 선언 앞 공백으로 디버그 패키징이 실패해 선언을 첫 줄로 옮겼다. 백업 복원에서 동일 장부를 서로 다른 SQL 공백으로 비교하던 문제를 공용 정의와 정규화로 수정했다. 파일 용량 검사는 회원별 집계 행을 써서 오래된 예약 전체를 읽지 않도록 조정했다.

재현은 [서버 가이드](BACKEND_GUIDE.md)와 `npm run lint && npm test`, `npm run db:migrate && npm run smoke:api && npm run build:api`, 모바일의 `flutter test --no-pub`를 사용한다. [DEV-03 PR 및 CI](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-03-backend-infrastructure)

## DEV-04 회원 인증과 세션

| 검사 | 결과와 근거 |
|---|---|
| DEV-00~03 회귀 | 변경 전 Flutter 82건·API 26건을 재현했다. Windows 최종 기본 실행은 Flutter 99건(신규 17), API 33건(신규 7)이다. 기존 Golden, 5탭, 화면 경로 58개, 링크 9종을 유지했다. |
| 실제 로컬 인증 | `npm run test:membership`가 공식 Firebase Auth Emulator와 workerd·D1에서 통과했다. 합성 이메일 가입·로그인·오류, OOB 발급·잘못된 코드·재사용, 동시 최초 가입, 정책·프로필 수정 충돌, 세션 갱신·기기 철회, 비밀번호 재설정 뒤 기존 세션 거부를 검증했다. Flutter Dart 게이트웨이도 같은 로컬 서비스를 호출해 가입에서 로그아웃까지 통과했다. |
| 인증 경계 | 로컬 RSA 서명, 서명 오류, unsigned, kid/키 회전, 프로젝트·시간·이메일 상태, 공급자 disabled/validSince, 회원 및 기기 소유권, 공식 권한과 관리자 추가 인증을 시험했다. 기본 빌드 진입에는 Emulator 바인딩이 없다. |
| D1/복구 | 실제 D1에서 빈 설치, v4 보존 업그레이드, 반복 실행·체크섬 및 실패 복구를 검증했다. 6개 마이그레이션과 장부 포함 38개 테이블이다. 합성 백업의 별도 복원·삭제 일지 재적용 시험도 통과했다. |
| 비용 | 동일 로컬 조회 12회의 D1 읽기 행은 1,276→391, 쓰기 행은 112→31이다. 쿼리별 집계 인덱스 변경 추정은 48→12다. 세션 최근 이용 기록은 조회 중 쓰지 않는다. 공유 승인과 철회는 D1을 통한다. 70·80·90·95·98% 가드 및 12개 기능 플래그를 유지했다. |
| 일본어 UI | 가입 레이아웃을 320·390·430·768dp × 100·130·200%에서 검사했다. 이메일 키보드·자동완성·인셋, 로그인 후 딥링크 복귀, 서버 재시도·로컬 자격 복원 및 해제를 확인했다. 합성 화면 PNG 5개는 무시된 `.local/dev-04-preview/`에 둔다. |
| 앱 빌드와 APK | Windows Flutter 번들과 ARM64 대상 디버그 APK를 생성했다. APK는 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`이며 `apksigner verify`에서 v2 서명을 확인했다. 개발 플래그를 켜고 만든 ARM64 릴리스의 매니페스트는 평문·백업을 차단한다. 디버그에 있는 개발 인증·딥링크·코드·설치 표지의 다섯 대표 문자열이 릴리스 AOT에 없음을 확인했다. |
| 저장소·의존성 | TypeScript·ESLint·API 빌드, actionlint, 요구사항 125개와 문서 28개 검사 통과. 프로젝트 npm 잠금 파일은 취약점 보고 0건이며 Pub 호스팅 잠금 의존성 65개는 OSV 보고 0건이다. 별도 Firebase CLI 15.37.0의 npm 의존성 감사에는 중간 심각도 항목 14개가 있다. CLI는 테스트 및 loopback Auth 전용으로 두고 운영 패키지에는 포함하지 않는다. |
| 공개 범위 | 원본 54개의 SHA-256이 로컬 기록과 일치했다. 공개 Git의 브랜치·태그·PR 이력 및 DEV-04 후보의 보호 미디어·개인정보·시크릿 패턴을 검사했다. 기존 CI 이미지 두 개는 저장소의 독자 생성 Linux Golden과 해시가 같다. |
| 후속 확인 | Emulator의 OOB 저장소에서 코드의 시간 경과 만료를 재현할 수 없어 앱의 만료 응답 처리까지 확인했다. 실제 운영 프로젝트·이메일·Cloudflare CPU와 비용, iOS 설치, Android/iOS 실기기 보호 저장소와 접근성·배터리는 미검증이다. |

테스트에서 Workerd가 거부하는 Fetch redirect 옵션을 수정했다. 일반 프로필 쓰기와 세션 철회를 같은 제한으로 계산하던 문제는 철회 전용 제한으로 해결했다. Flutter 통합 시험의 HTTP 모의 응답을 전용 루프백 연결로 분리해 실제 Firebase와 D1을 사용하도록 교정했다. 철회 이력이 많을 때 활성 기기가 목록에서 사라지던 경계 사례를 고쳐 현재 기기와 나머지 활성 기기를 먼저 표시한다.

재현은 [에뮬레이터 가이드](FIREBASE_EMULATOR_GUIDE.md), [비용 통제](COST_CONTROL_GUIDE.md), [DEV-04 PR 및 CI](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-04-membership-auth)에서 확인한다.

## DEV-05 팬 게시판

| 검사 | 결과와 근거 |
|---|---|
| 기준 회귀 | 시작 시 DEV-04 Flutter 99건, API 33건을 재실행했다. 신규 Flutter 16건으로 전체 115건, 신규 API 5건으로 전체 38건이다. 기존 Golden, 5개 탭, 58개 화면 경로와 9종 링크를 유지했다. |
| 일본어 UI | 320·390·430·768dp × 100·130·200%에서 폼과 키보드 인셋을 점검했다. 320dp/200%에서 장문 10,000자를 입력했다. 기존 로컬 F01/F03 두 참조는 1284×2637px이며 흰 영역과 행 구분을 비교했다. 합성 PNG는 `.local/dev-05-preview/`에 저장한다. |
| 데이터와 HTTP | Unicode 16 공통 말뭉치와 9,999/10,000/10,001 경계, 태그 10/11개, 정규화 중복, 조건부 수정·삭제 경합, 멱등 재전송을 실제 D1에서 확인한다. 워크로드는 2,200개 게시물, 커서 및 최신순 인덱스를 사용한다. |
| 통합 | Firebase Auth Emulator·workerd·D1에서 일반 합성 회원 2명으로 작성·인용·신고·차단·삭제를 실행했다. D1 시험은 합성 공식 아티스트와 고정 공지·일반 구분을 검증한다. 계정 변경, 버전 충돌, 철회 응답은 이전 통합과 함께 검사했다. Flutter는 실제 로컬 서비스에 연결해 가입·인증, 9,999자·10,000자 작성과 10,001자 거부, 목록 조회를 검증했다. |
| 로컬 초안 | 실제 Drift SQLite v1→v2 업그레이드와 재열기, AES-GCM 암호문, 계정 분리, 일반 로그아웃 유지와 확정 만료 시 삭제를 검사한다. 작성 화면의 600ms 디바운스는 마지막 완료 저장 이후 강제 종료 손실 여지가 있다. |
| 성능·비용 | 동일 목록 조회 12회에서 읽기 27,559→1,159행 및 쓰기 31행. DEV-04 보호 상태 조회 391/31행과 별도로 집계했다. 100/500/1,000/5,000 MAU와 7가지 부하 추정은 비용 문서에 둔다. |
| 공급망 | 프로젝트 npm 감사와 Pub 잠금 항목 74개의 OSV 조회는 각각 보고 0건. 독립 개발 도구 `firebase-tools@15.37.0` 감사는 중간 등급 항목 14개다. 실제 권고 4건이 아래 간접 의존성을 통해 전파된다. |
| 빌드 | Flutter 번들과 ARM64 대상 Android 디버그 APK, APK Signature Scheme v2를 검증했다. 개발 플래그를 켠 릴리스에서 평문과 백업 금지 및 개발 인증·초안 경로의 대표 문자열 여섯 개 비포함을 확인했다. |
| 후속 | Windows 환경의 iOS 빌드, 실제 기기 백업·보안 저장소, 물리 기기 프레임·배터리, 운영 CPU와 공급자 청구량, 실제 공유 링크는 미검증이다. |

Firebase CLI 실행 범위는 로컬 및 CI의 demo 프로젝트 Auth 서비스다. 현재 npm 최신 상위 버전은 15.37.0이며 npm의 제안은 13.11.2로 되돌리는 호환성 변경이다. 의존성 강제 치환은 적용하지 않았다. 도구는 loopback, 합성 입력만 사용하며 Worker와 앱 번들에 포함되지 않는다. 다음 Firebase CLI 릴리스 또는 DEV-06에서 업스트림 변경과 에뮬레이터 E2E를 다시 확인한다.

| 권고 | 설치된 간접 의존성과 영향 조건 |
|---|---|
| [GHSA-8988-4f7v-96qf](https://github.com/advisories/GHSA-8988-4f7v-96qf) | @opentelemetry/core 1.30.1 및 Pub/Sub 경로. 외부 W3C Baggage를 파싱하는 환경의 메모리 과다 할당. |
| [GHSA-3g3m-2fjr-6pw4](https://github.com/advisories/GHSA-3g3m-2fjr-6pw4) | glob 10.5.0 및 archiver·exegesis·rimraf 경로. 취소 이후 파일 탐색이 이어지는 조건. |
| [GHSA-g3hv-75wg-m249](https://github.com/advisories/GHSA-g3hv-75wg-m249) | minimatch 9.0.9의 glob 경로. 신뢰할 수 없는 glob 입력의 자원 사용량 증가. |
| [GHSA-w5hq-g745-h8pq](https://github.com/advisories/GHSA-w5hq-g745-h8pq) | uuid 9.0.1 및 gaxios 계열. 버퍼를 받는 일부 버전 생성 호출의 경계 처리. |

실제 D1 시험으로 혼합 SQL 바인딩과 신고 서브쿼리 바인딩 문제를 수정했다. workerd가 본문 없는 PUT을 빈 스트림으로 전달하는 경우를 허용하고 실제 바이트가 있는 요청은 거부한다. 조회에는 최신순 인덱스를 지정했다. 조건부 갱신이 0행일 때 멱등성 성공과 부수 기록이 남지 않도록 전체 배치를 종료한다. [운영 범위](OPERATION_GUIDE.md) · [Firebase CLI 릴리스](https://github.com/firebase/firebase-tools/releases/tag/v15.37.0)


## DEV-06 사진과 공식 갤러리

| 항목 | 결과와 범위 |
|---|---|
| Flutter | 134건 중 신규 19건. 기존 Golden과 내비게이션·회원·게시판 회귀, 320/390/430/768dp × 100/130/200%, 암호화 사진 초안, 첨부 상한·순서, 뷰어 확대 상태, 갤러리와 프로필 화면. |
| API | 43건 중 신규 5건. 실제 로컬 D1 v7→v8과 빈 DB, 기존 데이터 및 장부, 썸네일 인덱스, 격리·승인·상태·취소·수명주기와 실제 R2 바이트. |
| 로컬 통합 | `npm run test:membership`는 실제 Firebase Auth Emulator·workerd·D1·R2, 일반 회원 두 명과 합성 공식 앨범에서 업로드, 타 회원 열람, 차단 및 삭제 후 거부를 통과했다. opt-in Flutter Gateway 시험에서 1,920×1,440px JPEG·썸네일의 실제 업로드·검역·게시물 연결·바이트 재열람도 통과했다. |
| 검역·개인정보 | JPEG 세그먼트, MIME·스트림 길이·SHA·해상도·디코딩, 후행·절단·EXIF GPS, 허용된 Range, 권한 철회·격리·소유자·부모 문맥, 누락 객체 역대사를 검증했다. 이미지 픽셀의 개인정보 및 네이티브 HEIC 처리는 출시에 앞서 확인한다. |
| 비용과 복원 | DEV-05 목록 12회 읽기 1,159행·쓰기 31행 유지. 별도 혼합 사진 경로 읽기 4,124행·쓰기 317행, R2 PUT 9회, GET 6회, HEAD 4회, 무료 DELETE 5회. 검사 도구 호출을 포함하는 로컬 수치다. v8 암호화 논리 백업을 별도 로컬 DB로 복원해 데이터와 스키마를 비교했다. |
| 요구사항·권리 | 125개 ID, 53개 화면 참조, 총 원본 54개 SHA-256 일치. 앱과 서버 로그는 경로나 비밀을 노출하지 않도록 시험했다. 로컬 생성 미디어·백업·원본은 Git에서 제외한다. |
| 의존성 | npm 루트 감사 0건, Pub OSV 94개 조회 0건. Firebase CLI 15.37.0은 현재 호환 수정 릴리스가 확인되지 않았다. CLI 감사의 중간 14개 항목은 glob, minimatch, uuid, @opentelemetry/core 등 개발 의존성 경로다. 로컬/CI loopback 합성 데이터만 사용하고 앱·Worker 번들에서 제외한다. |
| Android 빌드 | Flutter 번들과 ARM64 debug APK를 생성했다. SDK 36, 최저 API 24, APK Signature Scheme v2 서명 검증 통과. 의도적으로 개발 플래그를 넘긴 ARM64 release 빌드에서 양성 대조 7개 개발 문자열이 제거됐고 평문 HTTP 및 백업 설정은 꺼져 있었다. |
| Android CI | 공식 Maven Central HTTP 429 로그에만 15초·30초 백오프를 적용한다. 테스트, 서명 및 다른 Gradle 오류는 해당 재시도 대상에서 제외된다. |
| 남은 검증 | iOS 빌드, 실제 카메라·HEIC 및 제한 사진 접근·OS 저장소, 실기기 프레임·메모리·배터리, 운영 Cloudflare CPU·청구, 실제 R2 직접 서명 인프라와 권리 승인. |

API 재현은 `npm run lint`, `npm test`, `npm run test:membership`, `npm run db:migrate`, `npm run smoke:api`, `npm run build:api`, `npm run check:repo`를 사용한다. Flutter에서 `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build bundle --no-pub`와 Android ARM64 APK 빌드를 실행한다. 로컬 통합은 수동 Emulator와 Worker를 켠 뒤 `flutter test --no-pub --dart-define=DEV04_LIVE=true test/membership_test.dart --plain-name 'Dart gateway connects to the real local emulators'`를 실행한다. 대표 프리뷰는 `DEV06_PREVIEW=true`로 로컬 `.local/dev-06-preview/`에 기록한다.

Firebase CLI의 직접 도구 릴리스와 간접 알림을 분리했다. 감사 알림의 직접 대상은 전부 간접 설치된 @opentelemetry/core <2.8.0, glob 9.0.0~14.0.1, minimatch 7.0.0~11.0.0, uuid <11.1.1이다. 나머지 10개는 해당 패키지에 도달하는 상위 의존성 경로 항목이다. 이 검사는 운영 서비스에서의 악용 가능 여부를 확정하지 않는다. 벤더 수정 또는 호환 릴리스 출시에 맞춰 재검토한다. 이미지 관련 잠금 의존성은 Flutter image_picker BSD-3-Clause, image MIT, jpeg-js BSD-3-Clause다. jpeg-js 0.4.4는 2022 릴리스이며 검역의 해상도·메모리 상한과 재검토 항목을 유지한다. 네이티브 변환은 OS ImageDecoder/ImageIO를 사용하며 외부 사진 서비스에 전송하지 않는다. [glob](https://github.com/advisories/GHSA-3g3m-2fjr-6pw4) · [minimatch](https://github.com/advisories/GHSA-g3hv-75wg-m249) · [uuid](https://github.com/advisories/GHSA-w5hq-g745-h8pq) · [OpenTelemetry](https://github.com/advisories/GHSA-8988-4f7v-96qf)


## DEV-07 댓글과 반응

| 항목 | 결과와 범위 |
|---|---|
| Flutter | 기존 134건과 신규 15건. 댓글·답글, 스탬프 선택과 명시적 전송, 좋아요 합치기와 실패 복구, 320/390/430/768dp × 100/130/200%, 기존 Golden 및 내비게이션 회귀. |
| API | 기존 43건과 신규 4건. 빈 v9·v8 업그레이드, 신고 보존, 댓글·스탬프·권리·커서·동시 수정, 원댓글 자리 표시, 좋아요·Outbox·최근 활동, 댓글 사진의 실제 R2 및 삭제 재적용. |
| 실제 로컬 통합 | 세 일반 합성 회원의 Firebase Auth Emulator·workerd·D1·R2 통합을 확인했다. 사진 게시물, 댓글, 사진 답글, 게시물 및 댓글 좋아요, 취소, 수정, 신고·차단 및 사설 사진 접근 제한을 포함한다. 별도 Flutter 실제 연결은 JPEG 및 댓글 사진·답글·좋아요를 검증했다. |
| D1 | 2,300댓글의 SQL 21행 페이지에서 4,600→21 입력 행을 비교했다. 인증·레이트·가시성·응답 집계를 포함하는 20행 API 페이지는 읽기 248행·쓰기 13행이었다. 게시 목록 12회의 읽기는 1,159→1,411행이고 쓰기는 31행이다. 이 수치는 로컬 시험이다. |
| 비용 | [반응 및 비용 모델](REACTION_GUIDE.md)에 네 MAU 규모, 여덟 시나리오, 1~60개월 및 R2·D1·Outbox 추정을 기록했다. Workers 및 Firebase 운영 리소스 추가 비용은 0엔이다. |
| 의존성 | npm 루트 0건, Pub OSV 94개 조회 0건. Firebase CLI 15.37.0 개발 의존성 중간 14개 항목에 호환 수정 릴리스가 확인되지 않았다. 해당 CLI는 합성·loopback·CI 운영에 한정하며 앱 또는 Worker 번들에는 포함하지 않는다. 신규 런타임 패키지 또는 원본 스탬프 자산은 추가하지 않았다. |
| Android | Flutter 번들 및 ARM64 디버그 APK 빌드, APK Signature Scheme v2 확인. ARM64 릴리스에서 개발 전용 문자열 양성 대조 7개가 제거됐고 평문 HTTP와 백업이 비활성 상태다. |
| 보호·회귀 | 125개 추적 ID와 원본 54개 SHA-256, 공개 이력과 보호된 참조 경로, Gitleaks를 검사한다. 저장소의 Maven Central 429 처리와 12개 기능 플래그를 보존한다. |
| 대상 외 검증 | iOS 빌드 및 실제 Android·iOS의 권한·HEIC·배터리·스크린리더, 운영 CPU·청구·FCM/APNs 및 R03 권리 승인. |

재현은 `npm run lint`, `npm test`, `npm run test:membership`, `npm run db:migrate`, `npm run smoke:api`, `npm run build:api`, `npm run check:repo`다. Flutter는 `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze --no-pub`, `flutter test --no-pub`를 실행한다. `DEV04_LIVE=true`로 별도 Flutter Gateway 시험을 실행하며 `DEV07_PREVIEW=true`는 합성 프리뷰 4개를 로컬 경로에 저장한다.

수정한 문제는 Firebase 인증기의 Windows 콜드 스타트 준비 시간, 이메일 정규화, workerd의 빈 PUT 본문 처리, 모바일 경로 허용 목록, 실제 댓글 링크의 부모 확인과 회귀 호환이다.
