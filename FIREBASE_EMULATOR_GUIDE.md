# Firebase Authentication Emulator

`demo-soramaru-auth`의 Auth 서비스를 127.0.0.1:9099에 바인딩한다. 에뮬레이터 제품은 Auth만 실행하고 브라우저 콘솔과 실제 인증 이메일을 사용하지 않는다. 다른 에뮬레이터가 포트를 점유한 경우 시작을 거부한다.

저장소의 E: 환경 설정을 적용한 뒤 실행한다.

```powershell
npm install --prefix .local/sdk/firebase --ignore-scripts --no-audit --no-fund firebase-tools@15.37.0
npm run db:migrate
npm run auth:emulator
```

다른 콘솔에서 `npm run auth:worker`를 실행한다. 앱 경로에서 Android Emulator는 `flutter run --dart-define=DEV_MEMBERSHIP=true`를 사용한다. 로컬 주소를 명시할 때는 `DEV_MEMBERSHIP_HOST`를 사용하며 허용된 개발 주소에 한정한다. 두 개발 프로세스는 각 콘솔에서 Ctrl+C로 중지한다. 로컬 사용 시 `example.invalid` 합성 계정만 입력한다. 디버그에서 이메일 화면에 코드 입력란을 제공한다.

`npm run test:membership`는 전용 에뮬레이터와 별개 테스트 D1에서 workerd를 실행한다. 로컬 공식 `/emulator/v1/projects/demo-soramaru-auth/oobCodes` 경계에서 코드를 메모리로 읽어 테스트하고 종료 시 에뮬레이터 테스트 계정을 정리한다. 원시 링크·코드·메일은 출력하거나 커밋하지 않는다. Firebase Emulator 15.37.0은 코드의 존재·재사용을 시험할 수 있으며 현재 OOB 저장소의 실제 시간 경과 만료는 제공하지 않는다. 클라이언트의 만료 응답 처리는 독립 시험하고 운영 만료는 승인 후 확인한다. [Firebase Emulator 문서](https://firebase.google.com/docs/emulator-suite/connect_auth) · [Firebase 인증 REST](https://firebase.google.com/docs/reference/rest/auth/)

에뮬레이터 전용 Worker 입력은 Vite serve에서만 고를 수 있다. 프로젝트 루트의 빌드와 CI 회귀 smoke는 별도 기본 진입을 사용한다. 날짜를 포함한 개발 키·로그·DB는 E:의 무시된 `.local/` 경로에 둔다.

로컬 서비스가 실행 중이면 `apps/mobile`에서 `flutter test --no-pub test/membership_test.dart --dart-define=DEV04_LIVE=true`로 Dart 게이트웨이를 실연결 시험한다. 로컬 Noto Sans JP 글꼴을 `.local/downloads/NotoSansJP.ttf`에 두고 기존 E: Flutter SDK를 사용하면 `--dart-define=DEV04_CAPTURE=true`로 PNG 5장을 생성한다. 두 검사는 기본 자동 테스트와 별도다.

도구 전용 npm 검사에서 Firebase CLI 15.37.0의 중간 심각도 의존성 항목 14개를 관찰했다. CLI는 공용 HTTP 접근이나 운영 자격 없이 합성 Auth 시험에만 사용한다. 업스트림 수정 버전이 공개되면 잠금 버전을 갱신하고 통합 시험을 다시 실행한다.

## DEV-08 연동

2026-11-27 레지스트리 최신 Firebase CLI는 15.37.0이다. 개발 도구에 중간 항목 14개가 남아 있다. 직접 의존성은 firebase-tools이며 Pub/Sub, OpenTelemetry, archiver, glob, minimatch, UUID 등을 포함한 나머지는 전이 패키지다. 네 가지 직접 advisory ID는 GHSA-8988-4f7v-96qf, GHSA-3g3m-2fjr-6pw4, GHSA-g3hv-75wg-m249, GHSA-w5hq-g745-h8pq다. Auth Emulator는 루프백 및 합성 데이터 전용이며 운영 의존성 검사와 분리한다. 호환 업그레이드가 확인될 때 재검사한다.
