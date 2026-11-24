# 출시 후보 점검

DEV-00에서 배포 및 스토어 등록을 수행하지 않는다. 아래는 DEV-16/17에서 증거를 확보할 출시 게이트다.

- [ ] 앱 명칭·공식 계정/초상/음원·사진/카드·스토어 미리보기 및 배포 지역 권한이 기록되어 있다.
- [ ] 일본어 iOS/Android 디바이스에서 설치/업그레이드/저장/삭제와 다섯 탭 접근성·증대 글꼴·Safe Area·상태 전환을 확인했다.
- [ ] 앱 내 UGC 약관 동의, 필터링, 신고 및 처리, 차단, 지원 연락처가 작동한다. 심사용 테스트 회원/절차를 별도 자격으로 제공한다.
- [ ] 앱 내와 외부 계정 삭제 요청 URL·접수/검증·연계 데이터 소거·보유 기간 공개가 확인되었다.
- [ ] Mac Xcode에서 `flutter build ios --simulator`, `flutter build ios --no-codesign` 및 실제 장치 서명/설치를 검사한다. 무료 개발 테스트와 스토어 배포 자격을 분리한다.
- [ ] APNs signing key·entitlement·권한 거부·재로그인·토큰 갱신, 딥링크 검증 파일, 화면 전환을 실제 iPhone과 Android에서 확인한다.
- [ ] iOS/Android에서 AAC 96/128, 잠금 화면/이어폰/통화/백그라운드/다운로드/네트워크 만료·재시작을 확인한다. 마이크·사진 권한 설명과 앱의 배터리/메모리 사용을 측정한다.
- [ ] 개인정보 보존·연령 등급·스토어 Data Safety/Privacy Details·앱 개인정보 정책·라이선스를 승인했다.
- [ ] MFA·권한/감사 로그·시크릿 방어·R2 비용 한도·예산 차단·서비스 비상 제한·D1/R2 백업 복원을 훈련했다.
- [ ] RC 테스트 결과와 모든 요구사항의 상태를 검토했다. iOS/Google Play 가입비/계약은 서버 모델에서 제외하며 별도 승인 필요. 실제 서비스 공개/운영 배포는 이 저장소 초기 요청 범위 밖이다.

[Flutter iOS 설정](https://docs.flutter.dev/platform-integration/ios/setup) · [Apple 개발자 계정](https://developer.apple.com/help/account/basics/about-your-developer-account) · [Google Play 등록](https://support.google.com/googleplay/android-developer/answer/6112435) · [보안 정책](SECURITY_POLICY.md)

## DEV-01 이후 유지할 항목

- [ ] 출시 빌드에서 `DEV_PREVIEW`를 기본 비활성 상태로 두고 카탈로그·합성 콘텐츠 경로 비노출을 실제 기기에서 확인한다.
- [ ] VoiceOver·TalkBack의 일본어 읽기 순서, 200% 시스템 글꼴, 회전, 실제 키보드와 뷰 인셋을 확인한다.
- [ ] 실제 기기 프레임 시간·메모리·배터리를 네트워크와 재생 기능 추가 후 측정한다.

## DEV-02 이후 추가 기기 확인

- [ ] iOS 시뮬레이터 및 실기기에서 일반 화면 뒤로 스와이프, 작성 종료 확인, 전체 화면 닫기, 회전과 시스템 Safe Area를 검사한다. Android 실기기에서도 시스템 및 예측 뒤로가기, 실제 키보드와 탐색 스택을 확인한다.
- [ ] VoiceOver·TalkBack으로 탭 배지·선택·헤더·접근 제한·오류 복구의 자연스러운 읽기와 포커스 순서를 확인한다.
- [ ] 운영 Universal Links/App Links의 서명·도메인 검증, 실제 콜드/웜 전달, 재로그인, 계정 변경 및 권한 철회 후 재검증을 검사한다.
- [ ] 실제 운영 인증으로 교체된 릴리스에서 개발용 기능의 비활성 상태를 확인한다. 대표 기기에서 연속 탭 변경의 메모리·프레임 시간·배터리를 측정한다. [내비게이션 안내](NAVIGATION_GUIDE.md)
