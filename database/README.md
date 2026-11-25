# 데이터베이스

D1 마이그레이션은 DEV-03부터 이 디렉터리의 `migrations/`에 순서대로 추가한다. [논리 모델과 검증 기준](../DATABASE_DESIGN.md)을 유지한다.

## DEV-03

스키마는 `migrations/`에서 버전과 SHA를 관리한다. Vite를 중지한 뒤 `npm run db:migrate` 또는 `npm run db:seed`를 실행한다. 레코드와 파일은 E:의 무시된 로컬 경로에 둔다. [마이그레이션](../DATABASE_MIGRATION_GUIDE.md) · [백업·복구](../BACKUP_RESTORE_GUIDE.md)
