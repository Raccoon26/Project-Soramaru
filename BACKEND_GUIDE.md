# DEV-03 서버 기반

## 로컬 실행 및 중지

Node 24와 기존 잠금 파일을 사용한다. Windows에서는 [README의 E: 환경](README.md)을 적용한 뒤 저장소 루트에서 실행한다.

```powershell
npm ci --ignore-scripts --no-audit --no-fund
npm run db:migrate
npm run db:seed
npm run smoke:api
npm run dev:api
```

`db:seed`는 선택이다. 서버는 `127.0.0.1:8787`에만 바인딩한다. 별도 콘솔에서 `Invoke-RestMethod http://127.0.0.1:8787/v1/ready`로 시작 검사를 한다. 종료는 Vite 콘솔에서 Ctrl+C다. 마이그레이션, 백업, 초기화는 Vite 종료 후 실행한다. 준비 검사는 스키마 버전과 두 R2 바인딩의 존재를 검증한다. 서비스 실험에는 합성 레코드만 사용한다.

| 환경 | 실행 정책 |
|---|---|
| Local | Cloudflare Vite 플러그인과 workerd. E:의 `.local/backend/local/v3/`에 D1 및 R2 저장. 미디어와 격리 버킷 분리. |
| Test | `SORAMARU_RUNTIME=test`. CI Vite 스모크는 비영속 DB. 직접 Miniflare 통합 시험은 사례별 새 D1/R2, 외부 요청은 테스트 프록시에서 차단. 테스트 CLI 데이터를 명시적으로 만들면 `.local/backend/test/`에 별도 저장. |
| Staging | 격리 자원과 비밀 참조의 설명용 템플릿. 실행 설정은 해당 값을 거부한다. |
| Production | 독립 자원·권한·승인·비용 검증 대기. 실행 설정은 해당 값을 거부한다. |

`services/api/config/environments.example.json`은 비활성 설정 인계용이다. 실제 환경 식별자와 자격 증명은 승인된 환경의 시크릿에 주입한다. Vite와 개별 바인딩 모두 원격 개발 연결을 끄며 계정 CLI와 배포 워크플로를 사용하지 않는다. [Cloudflare R2 로컬 개발](https://developers.cloudflare.com/r2/local-development/) · [Cloudflare Vite 플러그인](https://developers.cloudflare.com/workers/vite-plugin/)

## 정상 진입 경로

- `GET /v1/health`는 기존 liveness 응답을 제공한다. `GET /v1/ready`는 유효한 환경과 D1 버전, 바인딩 확인 후 준비 상태를 반환한다.
- `GET /v1/me/session`은 실제 검증기 연결 전 인증을 거부한다. 테스트 의존성은 테스트 모드에서만 가짜 검증기를 넣고 실제 로컬 DB의 상태·세션·역할을 확인한다. 권한 확인 뒤 앱의 레이트·비용 경계를 적용한다.
- 도메인 쓰기는 DB 서비스 계층에서 권한과 버전을 검증하고 멱등성 키 및 outbox와 함께 D1 batch로 커밋한다. 외부 I/O는 별도 멱등 작업이 처리한다. 단일 준비 쿼리의 바인딩은 100개 이내로 유지한다.
- Cron 수신 함수는 로컬에서 만료 예약을 처리한다. 유효한 작업의 게시 가시성은 요청 시 승인 및 `publish_at`으로 계산한다. 재시도, 임대 펜싱, outbox 소비는 도메인과 분리된 테스트 인터페이스로 검증한다. [Cloudflare Cron UTC](https://developers.cloudflare.com/workers/configuration/cron-triggers/)

## 후속 연동 및 운영 인수

DEV-04는 Firebase 검증기와 서버 세션 발급, DEV-05~08은 페이지/차단·권한과 D1 도메인 쓰기, DEV-06/09/11은 검역 판정·미디어 서명 및 재생, DEV-13은 outbox 수신·실제 알림과 삭제, DEV-14/15는 관리자 제어·공급자 지표·복구를 연결한다. 운영 활성화 전 저장소 권리 승인을 확인하고 Cloudflare·Firebase 환경/정책, R2 청구, 시크릿 수명, 지표 가시성, 복구 시험, Android/iOS 운영 연결을 별도 승인받는다. [비용 제어](COST_CONTROL_GUIDE.md) · [마이그레이션](DATABASE_MIGRATION_GUIDE.md) · [복구](BACKUP_RESTORE_GUIDE.md)

## DEV-04 개발 서버

`npm run db:migrate` 다음에 Firebase Auth Emulator를 별도 콘솔에서 실행하고 `npm run auth:worker`를 실행한다. 로컬 인증이 없는 기본 `dev:api`와 별도 진입이다. 에뮬레이터 인증 모드의 Worker 빌드는 거부한다. Windows·CI는 합성 데이터만 쓰며 운영 활성화에는 별도 승인이 필요하다. [실행 지침](FIREBASE_EMULATOR_GUIDE.md)

## DEV-05 팬 게시판

기존 `npm run test:membership`는 실제 Firebase Auth Emulator·workerd·D1에서 두 합성 회원으로 게시물을 작성하고 인용·신고·차단·삭제까지 실행한다. `node --test services/api/test/community.test.mjs`로 v6 업그레이드, 합성 공식 정체성, 경쟁과 비용을 확인한다.


## DEV-06 로컬 사진

`npm run db:migrate` → `node tools/photo-fixtures.mjs`로 합성 공식 앨범을 준비한다. Firebase Auth Emulator는 `npm run auth:emulator`, Worker는 `npm run auth:worker`로 각각 127.0.0.1 에서 실행한다. `npm run test:membership`는 자체 Emulator를 실행하므로 수동 Emulator가 종료된 상태에서 실행한다. [개발 절차](MEDIA_UPLOAD_GUIDE.md)


## DEV-07 댓글과 반응

DEV-07 통합은 로컬 v9와 테스트 회원을 사용한다. `node --test services/api/test/interactions.test.mjs`에서 부모 제약·스탬프·반응·R2·복원을 재현한다. `npm run test:membership`는 별도의 로컬 Firebase Auth Emulator와 workerd를 사용한다.
