# SOT/index.md — 현재 프로젝트 상태

> 이 파일은 5~15줄로 유지한다. 매 세션 시작 시 Claude가 읽는 유일한 상태 파일이다.
> 세션 종료 시 현재 상태로 갱신한다.

---

## 현재 상태

- **프로젝트**: claude-code-ai-native (AI-native 프로젝트 템플릿)
- **최근 완료**: 로컬 Supabase 포트 충돌 해결 (Cursor IDE 54321 점유 → 54331로 변경)
- **최근 완료**: schema_snapshot 마이그레이션 User 테이블 누락 수정, db reset 정상화
- **최근 완료**: coach-test@test.com 로그인 에러 수정 (auth.users NULL 컬럼)
- **최근 완료**: Smart Router 메타데이터 레지스트리 생성 (.claude/router/ 신규)
- **진행 중**: 없음
- **블로커**: 없음

## 주의사항

- Cursor IDE가 포트 54321을 점유하므로 로컬 Supabase는 포트 54331 사용 필수
- hook 차단은 `exit 2`만 유효 (`exit 1`은 통과됨)
- Bash를 통한 파일 수정은 DoD gate를 우회함 (알려진 한계)

---
*마지막 갱신: 2026-04-09 (Smart Router 레지스트리 생성)*
