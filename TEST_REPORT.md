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

- Flutter 3.50.1/Dart: format 및 analyze, 테스트 29건을 검증했다. 기존 DEV-00 일본어 시작 테스트 1건과 DEV-01 Golden 2건이 포함된다. Golden은 OFL 글꼴의 일본어 부분집합과 SDK 아이콘을 고정해 사용한다.
- 320/390/430/768 논리 px × 100/130/200%의 12조합에서 대표 프리뷰 10개(120개 렌더)를 확인했다. 별도로 가로 회전, 양쪽 안전 여백, 입력·키보드 인셋, 뒤로가기/모달, 안내 배너 아래 기존 데이터 유지, 알림 및 선택 semantics를 검사했다. 목표 대비는 본문 4.5:1, 필수 경계 3:1이다.
- 로컬 캡처를 기존 참조와 대조하고 누락된 테스트 아이콘 폰트, 진하게 표시된 기본 구분선과 회전·키보드 검증의 스크롤 타이밍을 수정했다. 캡처는 `.local/dev-01-preview/`에 저장되며 합성 Golden 2장만 Git에 포함한다.
- API lint, 타입 검사, workerd를 포함한 테스트 3건, API 번들, actionlint, npm audit(0건), 요구사항 및 Git 경로 검사 통과. 비교 기준과 제품 기능의 구현 일정은 추적표를 참조한다.
- Windows Flutter 번들과 ARM64 디버그 APK 빌드 및 `apksigner verify`를 통과했다. APK는 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`다.
- Flutter 프리뷰는 네트워크·미디어 디코딩·상태 카탈로그의 지속 애니메이션 없이 동작하도록 구성했다. 피드/알림은 지연 생성, 그림은 고정 도형 및 분리된 페인트 경계를 사용한다. 실제 기기 프레임 시간·배터리·VoiceOver·TalkBack·iOS 빌드는 미측정 또는 미검증이다.
- DEV-00 문서의 4커밋/104 blob은 PR #1 병합 전 원격 감사 범위다. 6커밋/112 blob은 DEV-00 문서 PR #2 병합 후 원격 범위다. 둘 다 도달 가능한 브랜치·태그·PR 기준이고 동일 blob은 중복 집계하지 않았다. DEV-01에서 원본 54건의 SHA-256을 다시 비교했다.
