# DEV-04 인증

개발 앱은 이메일·비밀번호를 localhost의 Firebase REST API로 보낸다. Worker는 Firebase ID 토큰을 검증한 후 D1의 회원 상태·문서 동의·프로필·기기 세션을 확인한다. 비밀번호와 이메일은 D1에 넣지 않는다. Firebase UID, 내부 UUID, 표시 번호는 독립 필드다. SMS와 소셜 로그인은 초기 범위 밖이며 후속 인증 제공자는 동일한 검증된 UID 계약을 따르게 한다.

## 가입 및 복구

1. メールアドレス와 パスワード/確認을 입력하고 개발용 세 문서를 확인한다. 암호는 12~128 Unicode 코드 포인트 기준으로 안내한다.
2. Firebase 인증이 성공하면 Worker에 앱 세션 발급을 요청한다. 일본어 이메일 확인 화면에서 링크 또는 로컬 OOB 코드를 적용한다.
3. 새 Firebase ID 토큰으로 서버에서 최신 정책 버전을 확인한다. 이메일 확인 전에도 자기 상태 확인·확인 요청·로그아웃이 가능하다.
4. 적용 중인 세 문서의 동의 행을 저장한 뒤 초기 프로필을 설정한다. 설정 이후 정상 화면으로 이동한다.
5. 비밀번호 재설정 요청은 기존 계정과 없는 계정에 같은 수신 안내를 반환한다. 코드를 확인하고 새 암호를 Firebase에 적용한다. Firebase 계정의 `validSince`와 D1 세션의 인증 시각을 함께 확인해 재설정 전 세션을 거부한다.

Firebase만 성공한 경우 인식 중인 토큰과 동일 발급 키로 다시 시도한다. 앱이 중간에 종료됐다면 같은 Firebase 계정으로 로그인할 때 회원 레코드를 복구한다. 가짜 로그인, Emulator 및 HTTP는 명시적인 디버그 경로에서만 연다. [에뮬레이터 가이드](FIREBASE_EMULATOR_GUIDE.md)

## 운영 JWT 계약

`productionFirebase`는 Web Crypto RSA SHA-256, 알고리즘·kid 고정, 서명·issuer·audience·subject·exp·iat·auth_time·이메일 확인을 검증한다. 키 조회 URL은 Google의 Firebase 서비스 JWK 경로에 고정한다. 응답의 캐시 수명 이내에서 키를 재사용하고 새 kid와 갱신 요청을 한 번으로 합친다. 임의 키 URL·무서명·만료 키·프로젝트 불일치를 거부한다. Firebase REST 계정 조회 결과의 UID, disabled, verified 및 validSince까지 대조한다. 계정 조회 장애에서는 보호 접근을 실패하도록 한다. 에뮬레이터 검증기는 별도 Vite 개발 진입 파일에 있다. 운영 배포, 키, Firebase 프로젝트는 승인 후 설정한다. [Firebase ID 토큰 검증](https://firebase.google.com/docs/auth/admin/verify-id-tokens) · [Firebase 세션 철회](https://firebase.google.com/docs/auth/admin/manage-sessions) · [Firebase REST API](https://firebase.google.com/docs/reference/rest/auth/)

Spark 표의 인증 이메일 1,000건/일, 주소 변경 이메일 1,000건/일, 비밀번호 재설정 150건/일, 신규 계정 생성 100건/IP/시간을 검토했다. 이메일 링크 로그인 서비스는 별도 한도이며 현재 사용하지 않는다. Identity Platform의 Spark 3,000 DAU 제한은 업그레이드 시 별도 적용된다. 직접 Firebase 로그인·가입과 앱 API의 제한 관할이 다르다. 운영 활성화 전 프로젝트별 한도, 이메일 열거 방지 설정, 연령 정책과 스토어 로그인 정책을 승인한다. [Firebase Authentication 한도](https://firebase.google.com/docs/auth/limits) · [Identity Platform 한도](https://firebase.google.com/docs/auth)
