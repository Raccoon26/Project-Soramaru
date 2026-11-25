# API 설계

## 규약

HTTPS JSON `/v1` 및 사용자 표시용 일본어 매핑. 응답에는 안정적인 기계 오류 코드, UI로 보내도 되는 필드 단위 오류, 절삭 추적 ID만 넣는다. 변경은 `Idempotency-Key` 또는 멱등 메서드, 편집은 버전/If-Match 충돌 409. 인증 누락/만료 401, 역할 부족 403, 접근을 숨겨야 하는 객체 404, 입력/API 경계 초과 400/413/415, 사용자 제한 429, 예산/점검 모드 503과 Retry-After. API가 허용하는 JSON 크기를 명시한다. 로그·오류에 원본 시크릿과 서명 URL은 넣지 않는다.

조회는 `?limit=20&cursor=...` 형태다. 서명된 불투명 커서에 사용자/뷰 조건, 마지막 정렬 키, 만료를 묶어 필터 이동이나 재사용 때 뒤섞이지 않게 한다. 피드는 내림차순 `created_at,id`. 알림은 읽지 않은 수의 스냅샷과 별도 페이지를 갖는다. 타깃 조회 시 차단·삭제·가시성 상태를 다시 검증한다.

| 주요 계약 | 권한 | DEV |
|---|---|---|
| `GET /v1/health` | 로컬 DEV-00의 무인증 liveness. 응답 `{"status":"ok"}` | 00 구현 |
| `POST /v1/sessions`, `GET/DELETE /v1/sessions/:id`, `GET/PATCH /v1/me`, `POST /v1/me/terms` | Firebase JWT로 앱 세션 생성, 소유자만 조회·철회. 인증/동의 상태 강제. | 04 |
| `GET/POST /v1/posts`, `GET/PATCH/DELETE /v1/posts/:id`, `GET /v1/tags/popular` | 가입·인증·게시 이용 동의. 자기 글 변경. 공식 표시용 grant 별도. | 05/08 |
| `GET/POST /v1/posts/:id/comments`, `PATCH/DELETE /v1/comments/:id`, `PUT/DELETE /v1/reactions/:kind/:id` | 차단·상태, 댓글 계층, 스탬프 권한, UNIQUE 멱등성. | 07 |
| `POST /v1/uploads`, `PUT /v1/uploads/:id/body`, `POST /v1/uploads/:id/complete`, `POST /v1/media/grants` | 예약 소유자. 1회 승인, 크기/수량 검증. 미디어 서명은 최대 20개 묶음. | 06/09 |
| `GET /v1/search`, `GET /v1/favorites`, `PUT/DELETE /v1/favorites/:type/:id`, `/v1/collections` | 정규화 키워드·태그·게시물. 폴더 CRUD, 저장한 리소스 상태 재검사. | 08 |
| `GET /v1/content/:kind`, `GET /v1/content/:kind/:id`, `/v1/me/recents`, `/v1/playlists` | 등록 회원. 상세와 트랙 참조. 오프라인 허가·라이선스 검사. | 06/08/09/10/11 |
| `/v1/notifications`, `PATCH /v1/me/notification-preferences`, `PUT/DELETE /v1/push-installations/:id` | 소유자. 읽기 이벤트 멱등 처리, OS 권한과 카테고리 설정 독립. | 13 |
| `GET /v1/me/card`, `GET /v1/me/badges`, `PUT /v1/me/badges/applied`, `GET /v1/me/message-cards` | 소유자. 카드 자격 검증에 고정 공개 QR 사용 금지. | 12 |
| `POST /v1/reports`, `PUT/DELETE /v1/me/blocks/:memberId` | 신고 대상/종류 검증, 반복 신고 제한, 개인정보 차단. | 05/07/08 |
| `POST /v1/me/deletion-requests`, `GET /v1/help`, `POST /v1/help/tickets`, `POST /v1/public/deletion-requests` | 앱 삭제는 최근 재인증. 외부 요청 시 이메일 소유 검증, 계정 유무 비공개, rate limit. | 13 |
| `/v1/staff/official/*`, `/v1/staff/moderation/*`, `/v1/staff/operations/*` | 별도 grant, 서버 측 범위 검사, 관리자 step-up·감사. 운영자 권한으로 아티스트 게시 금지. | 11/14 |

신규 엔드포인트는 구현 전에 계약과 권한을 갱신한다. 일반 모바일 API에는 웹 Origin 와일드카드가 필요 없다. 운영 웹은 동일 Origin 상위 경로에서 별도 세션을 사용하며 상태 변경에 Origin/CSRF 검사를 적용한다. 서명 발급과 미디어 콘텐츠 캐시는 토큰 유효 기간과 개체 버전을 고려하고 비공개 응답에 공유 CDN 캐시를 적용하지 않는다.

## 모바일 화면 이동과 서버 읽음 계약

DEV-02는 기존 Workers 상태 API와 공용 타입을 그대로 사용한다. 알림·링크 대상은 `종류 + 콘텐츠 ID`로 해석하고 댓글 ID의 상위 글은 데이터 계층에서 찾는다. URL과 복원 상태에는 토큰, 개인정보, 서명된 미디어 URL을 넣지 않는다. DEV-04 이후 각 대상 조회에서 세션·역할·가시성을 확인하고 만료(401)와 접근 제한(403/404)을 화면에 매핑한다.

알림 열기는 로컬 화면 이동이다. DEV-13에서 읽음 요청에 알림 ID를 사용하고 서버 성공 응답으로 읽음 상태와 배지 수를 갱신한다. 실패하면 기존 수를 유지하고 재시도할 수 있게 한다. 대상 로딩과 읽음 갱신 결과는 독립적으로 다룬다. 푸시 클릭과 앱 내 알림에는 같은 목적지 검증을 적용한다. [내비게이션 안내](NAVIGATION_GUIDE.md)

## DEV-03 공통 계약

`/v1/health`의 상태와 미지원 메서드의 405/Allow를 보존한다. `GET /v1/ready`는 유효한 모드·바인딩·스키마 버전에서 `{"status":"ready"}`를 반환한다. `GET /v1/me/session`은 유효한 세션의 유효 역할만 반환하는 기반이며 기본 실행에서 검증기가 연결될 때까지 401이다. 개발용 DI는 Test에서만 허용한다.

응답은 `no-store`, `nosniff`, 서버 생성 `X-Request-Id`를 쓴다. `{"error":{"code":"..."}}` 안의 기계 코드와 429/503의 `Retry-After`를 모바일에서 사용한다. JSON helper는 UTF-8 객체, 미압축 JSON MIME, 기본 16KiB 실제 스트림을 검증한다. 잘못된·중복 쿼리와 경로 인코딩 및 과대 요청을 거부한다. SQL·예외 원문 없이 상태·처리 시간·측정한 D1 메타 범위를 로그에 남긴다. 새 도메인 엔드포인트는 해당 권한·레이트·비용 우선순위 및 허용 요청 필드를 지정한다.

멱등성 키는 회원+작업+키 및 정규화 요청 해시에 연결한다. 결과·도메인 쓰기·outbox 등록은 동일 D1 batch다. 입력이 달라지거나 24시간이 지난 키는 409로 다룬다. 키 보존/정리 이후의 중복 방지는 도메인 고유 키로 적용한다. 외부 전달자는 이벤트 ID를 키로 재시도를 견뎌야 한다. [서버 안내](BACKEND_GUIDE.md)

## DEV-04 회원 API

| 메서드와 경로 | 계약 |
|---|---|
| POST /v1/sessions | Firebase 토큰, 무작위 발급 키, 기기 별칭·OS로 세션 발급 |
| GET /v1/me/session | 두 자격 증명으로 회원 단계·프로필·현재 세션 통합 조회 |
| POST /v1/sessions/renew | 만료 임박 세션의 제한 갱신 |
| GET /v1/sessions | 자기 기기 목록 |
| GET, DELETE /v1/sessions/:id | 자기 기기 상세·철회 |
| DELETE /v1/sessions | 재인증 뒤 전체 기기 철회 |
| GET, PATCH /v1/me | 자기 프로필. PATCH는 quoted `If-Match` 버전 |
| POST /v1/me/terms | 최신 정책 버전 및 세 문서의 멱등 동의 |
| GET /v1/auth/policies | 버전과 일본어 개발 문서 |
| POST /v1/auth/email | 메일 확인·재설정의 제한된 요청 |

일반 보호 요청은 `Authorization: Bearer` Firebase ID 토큰과 `X-App-Session`을 모두 사용한다. `POST /v1/sessions`는 발급 전이므로 Firebase만 사용한다. DEV-03 테스트 주입용 단일 Bearer 계약은 이전 회귀를 위해 격리했다. [세션 관리](SESSION_MANAGEMENT_GUIDE.md)

## DEV-05 팬 게시판

보호 경로는 `GET/POST /v1/posts`, `GET/PATCH/DELETE /v1/posts/:id`, `GET /v1/members/:id`, `POST /v1/reports`, `PUT /v1/me/blocks/:memberId`, `GET /v1/tags/popular`다. 목록은 `category`, `author`, `tag`, `cursor`, `limit`만 받으며 20/50 한도를 적용한다. 인기 태그와 즐겨찾기는 준비 상태이며 공유 링크는 승인된 도메인이 필요하다. [글 수명](POST_LIFECYCLE_GUIDE.md)


## DEV-06 사진 API

| 경로 | 요청 및 응답 |
|---|---|
| `POST /v1/uploads` | `Idempotency-Key`, JSON `purpose, bytes, mime, sha256, variantOf?`. 201 예약 상태. |
| `PUT /v1/uploads/:id/body` | `image/jpeg` 스트림, 예약 크기와 해시 검사, 200 격리 상태. |
| `POST /v1/uploads/:id/complete` | 소유자 요청으로 검역 및 승인, 200 상태. |
| `GET`, `DELETE /v1/uploads/:id` | 소유자 상태 200, 안전 취소 204. |
| `POST /v1/media/grants` | `parent, parentId, ids, variant, mode?`, 부모당 최대 20개, 순서 유지. |
| `GET /v1/media/:id` | `parent, parent_id, variant`, 인증된 JPEG 200/206과 private no-store. |
| `GET /v1/gallery`, `GET /v1/gallery/:id` | 공식 앨범 페이지와 정렬된 사진 ID. |

`POST/PATCH /v1/posts`의 선택적 `attachments`는 최대 10개의 순서 있는 게시용 ID다. 수정에서 필드를 생략하면 기존 사진을 유지한다. `PATCH /v1/me`의 `avatarMediaId`는 목적·소유권·프로필 버전을 적용하며 null은 제거다. 동시 변경·해시 충돌 409, 초과 413, 형식 오류 415, 부적절한 Range 416, 접근 실패 401/403/404, 레이트 429, 비용 또는 점검 503을 사용한다. [권한과 캐시](MEDIA_ACCESS_GUIDE.md)
