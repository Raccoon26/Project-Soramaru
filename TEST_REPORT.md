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
