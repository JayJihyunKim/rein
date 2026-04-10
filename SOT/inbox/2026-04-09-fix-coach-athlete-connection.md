# coach-test 선수 연결 및 로컬 Supabase 수정

- 날짜: 2026-04-09
- 유형: fix
- 변경 파일:
  - tracme-solution/supabase/migrations/20251229014001_schema_snapshot.sql (User 테이블 CREATE 추가)
  - tracme-solution/supabase/migrations/20260401100100_phase0_views_indexes.sql (exercise_quality_metrics 테이블 추가)
  - tracme-solution/supabase/config.toml (API 포트 54321→54331, major_version 17→15)
  - tracme-solution/.env.local (Supabase URL 포트 54331로 변경)
- 요약:
  - Cursor IDE가 포트 54321을 점유하여 원격 Supabase로 프록시하던 문제 발견 → 포트 54331로 변경
  - schema_snapshot 마이그레이션에 누락된 User 테이블 추가하여 db reset 정상화
  - coach-test@test.com + 10명 선수 테스트 데이터 생성 및 approved 연결
  - auth.users의 email_change NULL 컬럼 수정으로 GoTrue 로그인 에러 해결
