# 개발 아키텍처

## 확정 구성

| 영역 | 선택 | 구현 시점 |
|---|---|---|
| 모바일 | Flutter 3.50.1 / Dart 3.14, Material UI, Riverpod Provider/Notifier, go_router StatefulShellRoute | 앱 골격 DEV-00, 토큰 DEV-01, 5탭 DEV-02 |
| 로컬 데이터 | Drift 기반 SQLite. 계정별 DB/파일 디렉터리, OS 보안 저장소에 세션 관련 키. | DEV-04, 05, 10 |
| API | TypeScript, Cloudflare Workers Free, JSON v1. DEV-00은 Vite와 Cloudflare Vite 플러그인으로 로컬 workerd와 번들을 검증한다. | DEV-00 상태 확인, DEV-03 도메인 API |
| 데이터 | Cloudflare D1 Free. 주 DB와 작업 카운터를 먼저 한 곳에 두고 인덱스·행량을 측정한다. | DEV-03 |
| 미디어 | Cloudflare R2 Standard 비공개, 별도 격리 버킷, AES-GCM 백업. 운영 R2 사용은 예산과 청구 정책 승인 조건부. | DEV-06, 09, 15 |
| 회원 인증 | Firebase Authentication Spark 이메일+비밀번호와 이메일 소유권 확인. Workers에서 ID 토큰과 앱 세션을 각각 검증. | DEV-04 |
| 관리자 추가 인증 | Firebase 1차 인증 후 WebAuthn 사용자 검증을 요구하는 별도 관리자 세션. 브라우저 관리자 호스트를 RP ID로 고정. | 권한 데이터 DEV-04, 서비스용 절차 DEV-14 |
| 푸시 | FCM HTTP v1과 iOS APNs. 발송 의도/상태는 D1 outbox, 권한 거부 시 앱 내 알림함 유지. | DEV-13 |
| 작업 | Cloudflare Cron 1개로 제한된 배치 소진. 게시 가시성은 요청에서 `publish_at <= now` 검사. | DEV-03 기반, 알림 DEV-11/13 |
| 운영 웹 | React·TypeScript, Workers Static Assets. 앱의 일반 API와 구분된 운영 전용 Worker. | DEV-14 |
| CI | GitHub Actions Linux, 고정 버전 및 잠금 파일. 공식 Flutter 및 Actions 배포본. | DEV-00 |

앱 통신 경로는 Flutter → 인증된 HTTPS API → D1이며 앱은 읽기 허가를 받은 객체를 R2 S3 HTTPS 주소에서 바로 다운로드한다. 로컬 전용 상태 확인 Worker는 Workers.dev, 프리뷰 URL, 리소스 바인딩을 비활성 구성한다. 운영 시에도 전용 `<worker>.<account>.workers.dev` 및 R2 S3 서비스 URL을 사용할 계획이다. 운영 웹과 정책/계정 삭제 요청 페이지는 별도 Worker HTTPS 호스트로 분리한다. 회원용 PC 웹은 공용 API와 접근성 적용 가능한 화면 계약을 이용해 이후 추가할 수 있다.

Cloudflare Vite 플러그인의 프로그램 구성은 현재 RC이며 잠금 파일로 고정한다. 로컬 개발·빌드는 워크스페이스에서 Vite 직접 명령을 실행한다. 계정 CLI 작업이 허가되는 단계에는 지원 Node 버전과 `cf`의 워크스페이스 동작을 재검증한다. 개발/테스트/운영의 Firebase 프로젝트 ID, D1, R2, Worker 이름과 시크릿을 분리한다. 개발·CI는 workerd 및 Firebase Emulator Suite 기반 테스트로 확장한다.

[Cloudflare CLI와 프로젝트 개발](https://developers.cloudflare.com/cf/projects/) · [Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/) · [workers.dev 경로](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/) · [Flutter SDK 보관소](https://docs.flutter.dev/release/archive) · [Riverpod](https://pub.dev/packages/flutter_riverpod) · [go_router](https://pub.dev/packages/go_router) · [Drift](https://pub.dev/packages/drift)

## 미디어 흐름

1. 멤버가 첨부 예약을 요청한다. 서버는 권한, 게시물 제한, 기간당 바이트와 할당량을 원자적으로 예약한다.
2. 초기 업로드는 Worker가 크기를 제한하는 스트림으로 검역 스토리지에 적재한다. 단일 이미지 상한 800 KB와 썸네일 100 KB. 오디오는 일반 회원에서 차단하고 승인된 계정만 회당 최대 25 MiB/30분. 일정 수준 이상은 DEV-15에서 분할 업로드 여부를 재검토한다.
3. 사진은 앱에서 방향 수정·리사이즈·재인코딩한다. 서버는 선언된 Content-Type과 매직 바이트, 포맷/해상도/청크 구조를 대조한다. 메타데이터 제거와 완전한 파일 검증이 가능한 경로만 승인한다. 격리 중인 객체는 읽기 서명 대상에서 제외된다.
4. 게시/앨범/음성에 승인된 media ID를 연결한다. 소유자·게시 상태·차단 상태·리소스 종류를 확인해 최대 5분짜리 R2 GET(필요하면 별도 HEAD) URL을 발급한다. 즐겨찾기·다운로드 기록에는 객체 ID와 버전만 저장한다.
5. 앱은 `Range` 및 `206 Content-Range`로 AAC를 직접 재생한다. 만료·네트워크 변경 후에는 새 URL을 받아 저장한 위치에서 재개한다. DEV-09에서 R2 S3, iOS AVPlayer/Android Media3의 실제 Range·갱신 행동을 검증한다. 직접 연결 제한이 켜지면 Worker 경유의 인증된 단일 Range와 요청 예산 모드로 전환하거나 운영 정책에 따라 재생을 제한한다.

콘텐츠는 AAC-LC .m4a 96kbps 기본, 128kbps는 업로드 승인 시 선택. 30분 기준 약 21.6MB/28.8MB이므로 기본 최대 25MiB는 128kbps 30분에 부족하다. 초기 128kbps는 최대 25MiB 및 약 27분 이내로 제한하고, 두 상한을 각각 검증한다. 스마트폰 녹음은 재생·삭제·재녹음을 지원하고 서버 변환은 피한다. 예상 패키지는 `just_audio`, `audio_service`, `audio_session`, `record`. 플랫폼 단일 플레이어 인스턴스가 재생 큐·미니 플레이어·시스템 컨트롤을 공유한다. 통화/포커스와 연결 해제 시 일시정지한다. 백그라운드 화면 유지 없이 재생하고, 임시 다운로드는 체크섬 확인 후 원자적으로 이동한다. 다운로드 음악은 기기 보호 및 계정 분리 대상으로, 일정 시간(초기 7일)마다 온라인 이용 권한을 갱신하고 로그아웃/삭제 시 정리한다. 즉시 회수가 필요한 콘텐츠는 다운로드 비허용으로 지정한다. [R2 서명 URL](https://developers.cloudflare.com/r2/api/s3/presigned-urls/) · [just_audio](https://pub.dev/packages/just_audio) · [audio_service](https://pub.dev/packages/audio_service) · [record](https://pub.dev/packages/record)

## 일관성과 장애

- 게시/댓글/알림 이벤트와 outbox는 동일 D1 트랜잭션으로 반영한다. 예약 글은 시각 이후 읽기 가능하며 Cron 지연은 공지 발송 지연으로 드러난다. Cron이 중복 실행되면 임대와 이벤트 고유 키로 중복 작업을 줄인다. FCM 요청 성공 직후 장애에 대비해 알림 ID로 앱에서 중복 억제한다.
- 파일 상태는 `reserved → quarantined → approved → attached → deleting`이며, 실패/만료 스위퍼와 저장소 대사를 수행한다. 업로드 후 DB 실패를 복구 가능하게 설계한다. 소유자 단위 동일 해시의 승인 파일만 재사용할 수 있고 타 계정 중복 여부를 알려 주지 않는다.
- 운영자는 요청량·쿼리 행 수·객체 사용량·발송 큐 지연·오류율을 보되, 사용자 원문이나 URL의 서명 파라미터는 관측 데이터에서 제외한다. 운영 환경 구성 시 로그/트레이스 샘플링 및 저장 기간을 정한다.
- 앱 내 링크는 승인된 라우트와 서버 조회 ID만 수용한다. 초기에는 앱 내/푸시 상대 라우트로 딥링크를 완료한다. 외부 공유는 로그인 화면으로 연결하는 HTTPS 랜딩 또는 OS 공유 시트에서 공개로 허용된 메타데이터를 제공한다. Universal/App Links는 OS 검증 파일·서명·기기를 DEV-17에서 확인한다.
- 피크 조건의 가입/쓰기·미디어가 예산을 넘으면 가입 승인, 추천·알림 배치·비필수 작업을 먼저 줄인다. 비용 우선순위는 [비용 정책](COST_POLICY.md), 복구 절차는 [운영 가이드](OPERATION_GUIDE.md)에 둔다.

## DEV-02 모바일 경계

`Screen` 레지스트리가 내부 경로와 화면 ID, 권한, 탭, 표시에 필요한 정보를 제공한다. Riverpod에서 세션 세대당 라우터를 하나 유지한다. `StatefulShellRoute.indexedStack`은 첫 방문 때 로드하는 탭별 Navigator를 보존하고 비활성 탭의 Ticker를 끈다. 전체 화면은 루트 Navigator에 둔다. 플러터 복원은 탭·경로·열거형 필터·목록 위치에 적용한다. 검색어·합성 초안·알림 복귀 출처는 메모리에 두며 계정을 떠날 때 제거한다.

`NavigationResources`는 후속 읽기 경계다. 실제 인증 도입 시 서버 세션 및 권한을 바탕으로 계정 복원 자료를 검증한다. 데이터 재요청은 인증/가시성이나 수명 조건에서 판단한다. 로컬 합성 경로는 릴리스에서 빌드 플래그와 관계없이 차단한다. 백그라운드 오디오는 화면 수명과 독립적인 서비스를 DEV-09/10에서 연결한다. [내비게이션 안내](NAVIGATION_GUIDE.md)

## DEV-03 서버 연결

Cloudflare Vite와 고정된 Miniflare/workerd를 공유한다. Local/Test 바인딩 이름과 저장 경로를 구분하고 원격 바인딩을 막았다. 공개 liveness와 바인딩/스키마 준비 상태를 분리한다. Cloudflare 측의 운영 런타임은 향후 Workers와 Cron, D1/R2 및 승인된 Firebase에 의존한다. 개발 PC는 배포 후 요청 처리의 의존성이 없다.

D1이 선택 작업 예산, 기능 플래그, 예약 잔여량, 레이트와 작업 임대를 조정한다. 스토어와 D1은 개별 커밋 경계를 가지며 두 사본 용량을 예약한 상태에서 멱등 재시도 또는 대사로 수렴시킨다. MediaAccess의 직접 발급과 제한 중계는 소유권과 상태를 검증한다. 실제 파일 검역, 서명 자격 증명 및 공유 권한 저장소는 해당 단계에서 연결한다. [서버 안내](BACKEND_GUIDE.md) · [비용 제어](COST_CONTROL_GUIDE.md)

## DEV-04 인증 경계

Firebase의 신원·현재 revoked 기준, D1의 회원·정책·기기 세션·역할을 함께 적용한다. 모바일 Firebase 갱신·저장은 디버그 에뮬레이터 REST 및 OS 보안 저장소로 분리했다. 일반 배포 입력에는 로컬 인증 어댑터가 없고, 운영용 Web Crypto 검증은 실제 프로젝트 승인 후 연결한다. [인증 가이드](AUTHENTICATION_GUIDE.md)
