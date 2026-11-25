# 기기별 세션

`POST /v1/sessions`는 최근 인증 5분 이내의 Firebase 토큰, 무작위 256비트 발급 키, 기기 별칭과 OS를 요구한다. 세션 자격 증명은 서버 HMAC에 UID·인증 시각·발급 키를 결합해 결정한다. 동일 요청의 유효 기간 내 재전송은 같은 자격 증명을 복구하고 변경 입력에는 충돌을 반환한다. D1에는 SHA-256과 시각, 무작위 내부 세션 UUID만 저장한다.

보호 요청은 `Authorization: Bearer <Firebase token>`과 `X-App-Session: <opaque credential>`을 동시에 제시한다. Worker는 공급자 계정 상태를 확인하고 D1에서 소유자, 세션 시각, 철회, 회원 상태와 유효 권한을 확인한다. 앱 세션은 8시간 기본과 30일 절대 상한을 사용한다. 만료 15분 이내에서만 갱신을 쓰고 `last_seen`은 갱신 시각으로 표시한다. 20개 활성 기기 상한은 합성 환경에서도 원자적으로 적용한다. 오래된 만료 행은 Cron 한 틱에서 최대 20개 정리할 수 있다.

다른 기기 또는 전체 철회는 5분 이내 재인증을 요구한다. 자기 기기는 기기 화면/로그아웃 메뉴에서 종료할 수 있다. 모든 기기 종료는 `revoked_before`와 활성 행을 업데이트하며 비밀번호 변경 이후에는 Firebase의 `validSince` 이전에 생성된 앱 세션도 거부한다.

Flutter는 Firebase 갱신 토큰과 앱 자격 증명을 기기 보안 저장소에 두고 ID 토큰은 메모리에 둔다. Firebase REST 클라이언트를 사용한다. iOS는 ThisDeviceOnly 보호 등급을 쓰며 앱 샌드박스의 비밀 없는 캐시 표지가 사라지면 이전 자격 증명을 삭제한다. Android 백업은 비활성화한다. 디버그 프로필·기기 목록은 메모리와 계정 세대로 격리한다. 실제 Keychain·Android Keystore·재설치/기기 이전은 DEV-17 실기기에서 검증한다. [모바일 경로](NAVIGATION_GUIDE.md)
