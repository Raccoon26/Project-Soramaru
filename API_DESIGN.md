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
