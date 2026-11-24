# 예약 작업

DEV-03에서 작업 상태와 비용 제한을 설계대로 연결한다. 콘텐츠 공개와 알림 동작은 DEV-11과 DEV-13에서 구현한다. 처리 원칙은 [아키텍처](../../ARCHITECTURE.md)를 따른다.

## DEV-03

런타임의 Cron 진입점과 D1 임대·재시도·Outbox 소비는 `services/api/src/jobs.ts`에 있다. 하나의 Worker에서 시각이 지난 예약 만료를 수행하며, 등록된 처리기만 임대한다. 후속 DEV는 지원해야 하는 작업을 같은 계약에 연결한다. [서버 안내](../../BACKEND_GUIDE.md)
