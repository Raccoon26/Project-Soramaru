# 데이터베이스 설계

## D1 모델

애플리케이션은 UUID/ULID 텍스트 키, UTC Unix 밀리초 정수, 명시적 상태 및 FOREIGN KEY를 사용한다. 비즈니스 ID와 Firebase UID를 분리하며 Firebase 이메일은 D1 일반 프로필에 중복하지 않는다. 공개 회원번호는 전용 시퀀스의 중복 없는 난수/표시 식별자를 발급하고 삭제 후 재사용 금지. 민감 식별은 서버 검증에 의존한다. 모든 사용자 노출 목록은 차단 쌍과 삭제·숨김·공개시각을 판정한다.

| 테이블 | 핵심 열·제약 |
|---|---|
| members, member_profiles | members(id, auth_uid UNIQUE, member_no UNIQUE, joined_at, state, revoked_before); profiles(member_id PK, nickname, biography, avatar_media_id, birthday_month, birthday_day, collection_visibility). 생일 카드 동의 시 월/일만 별도 저장. |
| terms_acceptances | (member_id, document_version) UNIQUE, accepted_at. 동의 이력이 있는 활성 회원만 UGC 작성. |
| role_grants, official_identities | 권한 코드, 대상 UID, 상태, 시작·종료, 부여자와 검토자. 공식 인물 소유 UID 바인딩에 별도 승인·변경 감사. |
| member_sessions, staff_credentials, staff_challenges | session_hash, device_alias, uid, last_seen, revoked_at. WebAuthn 공개키와 검증 일회성 challenge, `expires_at`. 기기의 원식별번호 미수집. |
| posts, post_media, comments, comment_media | posts(author_id, displayed_identity_id, quote_post_id, body, created_at, publish_at, state, version); comments(post_id, parent_id, author_id, body, state, created_at). 답글 1레벨. 첨부의 순서·소유권·종류를 함께 검증. |
| tags, post_tags, popular_tags, favorites, blocks, reactions | 정규화 태그 UNIQUE, 연결 복합 PK, 인기 집계는 배치. favorites는 사용자·게시물·태그 대상으로 타입별 FK 또는 분리 테이블. blocks와 reactions는 대상 쌍 UNIQUE. |
| stamp_sets, stamp_items | 권리 상태·대상 객체·표시 기간. 댓글과 스탬프 항목은 FK 및 활성 검사. |
| media_objects, media_uploads, media_reservations | object_key UNIQUE, owner_id, scope, bytes, sha256, MIME, state, retention_until, variant_of, version. 발표 가능 객체만 제공. 예약은 expiry와 멱등 키. |
| content_items, gallery_items, audio_tracks | kind=word/voice/radio/gallery/notice, publisher_id, status, publish_at, moderation_state. track에는 media_id, duration_ms, bitrate, position, rights_scope. |
| playlists, playlist_tracks, recents | owner_id와 수정 버전. 최근은 (member_id, target_type, target_id) 갱신, 계정마다 100개 제한. |
| collections, collection_items | owner, folder, visibility, item type, order. 기본 비공개. 권한 확인이 끝난 객체만 표시. |
| notifications, notification_preferences, push_installations | 알림 (recipient_id, type, target, read_at, dedupe_key). 푸시 토큰/설치 ID 연결, 로그아웃·무효 응답 정리. |
| badge_catalog, badge_awards, applied_badges | 정의·부여 사유, (badge_id,member_id) UNIQUE, 적용은 부여 항목과 일치. |
| card_templates, card_deliveries | 유형 일반/생일/가입기념, 당사자별 dedupe_key, 적용일 JST. 권리 승인과 전달 가능 상태 기록. |
| reports, moderation_actions, support_tickets | 대상/분류/사유/우선순위/처리상태. 증거는 접근 격리. 조회 사유 및 담당자 기록. |
| scheduled_jobs, outbox, idempotency_keys | run_at, lease_until, attempts, state, payload version, dedupe_key UNIQUE. 쓰기 키는 actor+route+key UNIQUE. |
| usage_windows, feature_flags, audit_events, deletion_requests | 기간별 예약/소진량, 기능 제한 버전·사유·유효 기간, 감사 이벤트 append-only, 삭제 단계/타임라인. |

## 인덱스와 트랜잭션

- 목록과 커서는 `(created_at DESC, id DESC)`의 불변 순서를 쓴다. 피드 종류·저자·상태에 해당하는 복합 인덱스, 댓글 `(post_id,parent_id,created_at,id)`, 미확인 알림 `(recipient_id,read_at,created_at,id)`, Job `(state, run_at, id)`, 회원 상태별 운영 조회 인덱스.
- 공개 목록에서 `(state, publish_at DESC, id DESC)`, 콘텐츠 종류 필터는 `(kind,state,publish_at DESC,id DESC)`. 차단은 양방향 탐색이 서로 다른 인덱스를 이용한다. 검색은 유저/태그 prefix의 정규화 검색부터 구현하며 DEV-08에서 일본어 표본으로 FTS5/trigram의 정확도·용량을 프로파일링한다. 1~2자 질의는 제한된 prefix 쿼리 결과만 제공. 전체 스캔을 피하고 prepared statement 파라미터를 바인딩한다.
- 목표 읽기 20개 기본/50개 최대, `LIMIT pageSize+1`. 공개/삭제/차단을 적용한 조회가 집계 결과에도 일치해야 한다. 쓰기마다 인덱스 갱신 행과 활동·알림 fan-out을 측정한다. 전체 회원 알림은 공식 이벤트 포인터+읽음 워터마크로 읽기 시 합성해 개별 일괄 INSERT를 줄인다.
- D1 batch 또는 WHERE 조건/트리거로 quota 예약·상태 버전 갱신·outbox를 원자적으로 관리한다. 서버가 장시간 잠금을 유지하지 않는다. 삭제는 즉시 접근 차단 후 콘텐츠 연결/객체/인증을 재시도 가능한 작업으로 정리한다. 시각과 수치는 서버에서 계산하며 해당 보존 정책을 메타데이터로 남긴다.
- SQL 마이그레이션은 새 열→이중 처리→백필→구형 읽기 제거 순서. DEV-03에서 빈 DB와 이전 스냅샷을 각각 올린다. `EXPLAIN QUERY PLAN`과 D1 `meta.rows_read/rows_written`을 트래픽 표본으로 검증한다. 장애 시 D1 Time Travel 7일과 분리 백업 사용. [D1 한도](https://developers.cloudflare.com/d1/platform/limits/) · [D1 복원](https://developers.cloudflare.com/d1/reference/time-travel/)

## 기기 SQLite

드래프트 본문·태그·파일 참조, 계정별 최근 열람, 재생 위치, 재생목록 메타, 다운로드 상태·권리 임대·만료, 동기화 작업을 상태기계로 보관한다. 버전 기반 마이그레이션과 사용자가 로그아웃한 경우 데이터·다운로드·키를 삭제하는 흐름을 시험한다. 화면 캐시는 조건부 갱신하며 토큰이나 미디어 서명 URL을 DB에 넣지 않는다.
