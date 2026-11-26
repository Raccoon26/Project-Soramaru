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

DEV-02 **COMPLETE**. [PR #4](https://github.com/Raccoon26/Project-Soramaru/pull/4)를 병합한 최종 main은 `87bbf0c`이며 [CI가 통과했다](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45416715923).

| 영역 | 결과 |
|---|---|
| 모바일 화면 | 58개 화면 경로와 루트 리다이렉트 1개. 하단 5개 Navigator, 전체 화면 닫기, 작성 보존, 알림 8종 복귀, 일본어 문구·JST 표시. |
| 세션과 링크 | 합성 세션·역할, 계정 전환 시 초기화, 수명 범위를 나눈 복원, 허용 목록 기반 링크 9종. 서버 권한과 푸시 및 운영 OS 연결은 예정 단계에서 검증한다. |
| Windows 자동 테스트 | 기존 29건과 신규 45건을 포함한 Flutter 74건, API 3건. 운영체제별 Golden 기준은 유지한다. 상세 범위는 [테스트 보고](TEST_REPORT.md)에 기록했다. |
| 자료·비용 | 원본 54개는 로컬에서 보호한다. 실제 운영 인프라·도메인·자동 과금 설정을 생성하지 않았으며 추가 서버 운영비는 0엔이다. |
| 인수인계 | [라우트·복원 계약](NAVIGATION_GUIDE.md), [DEV-02 PR 및 검사](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-02-navigation), [main CI](https://github.com/Raccoon26/Project-Soramaru/actions/workflows/ci.yml?query=branch%3Amain). |

실제 iOS 빌드·제스처, VoiceOver·TalkBack, 실제 기기 프레임 시간·메모리·배터리는 [출시 점검](RELEASE_CHECKLIST.md)에 둔다.

## DEV-03 서버 기반

DEV-02 **COMPLETE**의 [PR #4 병합](https://github.com/Raccoon26/Project-Soramaru/pull/4)과 `main` 커밋 `87bbf0c`에서 시작했다.

| 영역 | 결과 |
|---|---|
| 실행 환경 | Vite/workerd Local 및 독립 Miniflare Test에서 D1과 비공개·격리 R2를 사용한다. Staging·Production은 비활성 템플릿이다. |
| 데이터 | SQL 4개와 35개 테이블(마이그레이션 장부 포함), 기존 요구사항에서 후속으로 계획한 20개 테이블. 버전·SHA 검증과 테스트 복원. |
| 비용·보안 | 공유 원자적 비용 승인, 12개 플래그와 필수 예산 여유, D1 레이트, 직접 미디어 지표 신선도 검사, 파일 예약·대사·작업 임대. |
| 모바일 | 공통 API 클라이언트와 일본어 상태 안내. 개발용 설정을 지정한 경우 사용자가 직접 연결을 확인한다. |
| 검증·인수 | [테스트 보고](TEST_REPORT.md) · [서버 안내](BACKEND_GUIDE.md) · [DEV-03 PR 및 CI](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-03-backend-infrastructure) · [main CI](https://github.com/Raccoon26/Project-Soramaru/actions/workflows/ci.yml?query=branch%3Amain) |

운영 리소스 생성과 배포 없이 추가 서버 비용 0엔을 유지했다. 운영 인증·실제 미디어·푸시·계정 삭제 처리, Cloudflare 운영 CPU와 청구량, iOS·Android 실기기 확인은 후속 단계에 둔다.

## DEV-04 회원 인증

DEV-03 **COMPLETE**는 [PR #5](https://github.com/Raccoon26/Project-Soramaru/pull/5)의 병합 커밋 `c188dd0`과 [최종 main CI](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45603491827)에서 확인한다.

이메일·비밀번호, 이메일 확인·비밀번호 재설정, 최신 정책 동의, 프로필과 기기 세션을 실제 Firebase Auth Emulator·workerd·D1에 연결했다. 기존 v1~4 SQL을 유지하고 v5~6으로 확장했다. 운영용 서명 검증기는 로컬 RSA 키로 검증하며 현재 기본 Worker와 릴리스 앱의 보호 기능은 닫혀 있다. [인증 가이드](AUTHENTICATION_GUIDE.md) · [DEV-04 PR 및 CI](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-04-membership-auth)

실제 운영 인증 이메일·Firebase 프로젝트·Cloudflare CPU와 청구량·iOS 빌드 및 실제 기기 보안 저장소는 후속 검증이다. 이번 서버 운영비 증분은 0엔이다.

## DEV-05 팬 게시판

DEV-04 **COMPLETE**는 [PR #6](https://github.com/Raccoon26/Project-Soramaru/pull/6), `bd61c288b8c9f616405530eb2fc7962517c8053f`와 [최종 CI](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45613644911)에서 확인한다. DEV-05의 범위와 검증 결과는 [팬 게시판 가이드](FAN_COMMUNITY_GUIDE.md)와 [테스트 보고](TEST_REPORT.md)에 기록한다.


## DEV-06 사진과 공식 갤러리

DEV-05 **COMPLETE**는 [PR #7](https://github.com/Raccoon26/Project-Soramaru/pull/7)의 병합 커밋 `2c448e4fe8007d8f9f7b362d963dd4f255b446f1`로 확인했다.

DEV-06은 사진 선택·정제·암호화 초안, D1 예약·R2 검역·승인, 원자적 게시물 및 프로필 연결, 문맥 기반 회원 열람, 사진 뷰어, 로컬 합성 공식 앨범을 추가했다. D1 v8은 장부를 포함해 41개 테이블이다. [사진 업로드](MEDIA_UPLOAD_GUIDE.md) · [검증 기록](TEST_REPORT.md) · [DEV-06 PR와 검사](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-06-photo-gallery)

실기기 사진 권한·HEIC·색상·배터리, iOS 빌드와 Cloudflare 운영 CPU·공급자 청구는 출시 검증에 남아 있다. 운영 리소스와 실제 계정 추가 및 서버 운영비 증가 없이 로컬에서 개발했다. DEV-07은 별도 지시 후 시작한다.


## DEV-07 댓글과 반응

DEV-06 **COMPLETE**는 [PR #8](https://github.com/Raccoon26/Project-Soramaru/pull/8)의 main 병합 커밋 `3b43688db33dd4f7788077fa3752b511d65f8b20` 및 [최종 CI](https://github.com/Raccoon26/Project-Soramaru/actions/runs/45638088621)로 확인했다. DEV-07은 댓글·답글·반응과 사진·스탬프, 활동, 신고, 알림 이벤트를 추가한다. 현재 검증 범위는 [테스트 보고](TEST_REPORT.md), 공개 변경은 [DEV-07 PR](https://github.com/Raccoon26/Project-Soramaru/pulls?q=is%3Apr+head%3Adev%2Fdev-07-comments-reactions)에 기록한다.
