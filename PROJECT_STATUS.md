# 프로젝트 상태

**2026-11-24(JST) · DEV-00 COMPLETE.** PR #1을 `main`에 병합했고 로컬 `main`을 갱신했다.

| 영역 | 결과 |
|---|---|
| Flutter | 일본어 최소 프리뷰, Android·iOS 프로젝트. Windows에서 Dart 포맷, 분석, 위젯 테스트 1건, ARM64 디버그 APK 빌드와 서명을 재확인했다. |
| API | TypeScript Workers 로컬 상태 경로, 공용 타입, Lint·타입 검사·번들 및 workerd 스모크를 포함한 테스트 3건 재통과. |
| 참조 | 스크린샷 53장과 영상 1개 분석. 원본 54건의 SHA-256이 최초 기록과 일치한다. |
| 공개 이력 감사 | 병합 전 원격이 광고한 브랜치·태그·PR 참조에서 도달하는 4개 커밋(임시 PR 병합 커밋 포함), 104개 고유 Git blob을 검사했다. 개인정보 값·인증 정보·보호된 참조 자료가 탐지되지 않았으며 바이너리는 Flutter 기본 이미지와 일치했다. |
| 구조·정책 | DEV-00~17 의존성, 125개 요구사항 ID와 필수 문서 19개. |
| GitHub | 사용자가 소스 저장소를 Public으로 전환하고 Allow auto-merge를 활성화했다. [PR #1](https://github.com/Raccoon26/Project-Soramaru/pull/1)의 검증 대상은 `57ffe10`, `main` 병합 커밋은 `0f5777b`다. [CI 두 작업](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45394581354)이 모두 통과했고 병합 시점에 필수 리뷰나 활성 브랜치 보호 규칙은 없었다. |

## 남은 검증과 승인

- Windows에서 iOS 빌드와 실기기 실행은 미검증이다. Mac/Xcode 시뮬레이터·무서명 빌드·실기기 설치와 이후 APNs·음성·백그라운드 동작은 [출시 점검](RELEASE_CHECKLIST.md)을 따른다.
- Android 실제 기기의 성능·배터리 및 릴리스 서명은 DEV-16/17에서 확인한다.
- 정식 명칭·초상·콘텐츠의 사용 허락과 실제 운영 계정 인수는 [권리 상태](RIGHTS_STATUS.md)의 대기 항목이다. `references/`와 로컬 파생물은 계속 Git에서 제외한다.
- DEV-00 운영 리소스, 도메인, 유료 계약, 서비스 배포는 생성된 내역이 없다. R2 운영 활성화는 청구 조건 확인과 승인 후 결정한다. Public GitHub Actions는 표준 호스티드 러너를 사용하며 워크플로에 배포 권한이나 아티팩트 업로드 단계가 없다.

## DEV-01 디자인 시스템

DEV-01 **COMPLETE**. DEV-00 최종 main 위에서 토큰·공통 컴포넌트·대표 프리뷰 10개를 구현했으며 [PR #3](https://github.com/Raccoon26/Project-Soramaru/pull/3)으로 병합했다. DEV-01 최종 main은 eb1bd5e다. 검증 결과는 [테스트 보고](TEST_REPORT.md), UX 결정은 [디자인 시스템](DESIGN_SYSTEM.md)에 있다.

## DEV-02 모바일 내비게이션

DEV-01 최종 main에서 `dev/dev-02-navigation`으로 진행했다.

| 영역 | 결과 |
|---|---|
| 모바일 화면 | 58개 화면 경로와 루트 리다이렉트 1개. 하단 5개 Navigator, 전체 화면 닫기, 작성 보존, 알림 8종 복귀, 일본어 문구·JST 표시. |
| 세션과 링크 | 합성 세션·역할, 계정 전환 시 초기화, 수명 범위를 나눈 복원, 허용 목록 기반 링크 9종. 서버 권한과 푸시 및 운영 OS 연결은 예정 단계에서 검증한다. |
| Windows 자동 테스트 | 기존 29건과 신규 45건을 포함한 Flutter 74건, API 3건. 운영체제별 Golden 기준은 유지한다. 상세 범위는 [테스트 보고](TEST_REPORT.md)에 기록했다. |
| 자료·비용 | 원본 54개는 로컬에서 보호한다. 실제 운영 인프라·도메인·자동 과금 설정을 생성하지 않았으며 추가 서버 운영비는 0엔이다. |
| 인수인계 | [라우트·복원 계약](NAVIGATION_GUIDE.md), [DEV-02 PR 및 검사](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-02-navigation), [main CI](https://github.com/Raccoon26/Project-Soramaru/actions/workflows/ci.yml?query=branch%3Amain). |

실제 iOS 빌드·제스처, VoiceOver·TalkBack, 실제 기기 프레임 시간·메모리·배터리는 [출시 점검](RELEASE_CHECKLIST.md)에 둔다. DEV-03의 Worker·D1·비용 차단 구현은 별도 단계다.
