# SOT/index.md — 현재 프로젝트 상태

> 이 파일은 5~15줄로 유지한다. 매 세션 시작 시 Claude가 읽는 유일한 상태 파일이다.
> 세션 종료 시 현재 상태로 갱신한다.

---

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **최근 완료**: v0.3.0 릴리즈 (브랜치 정리, COPY_TARGETS 수정, 서브프로젝트 AGENTS.md 가이드 통합)
- **진행 중**: 없음
- **버전**: v0.3.0
- **블로커**: GitHub 레포 리네임 수동 작업 필요 (Settings → Repository name → `rein`)

## 주의사항

- dev/main 워크플로우: dev에서 개발 → main에 템플릿만 merge (`--no-commit`으로 선별)
- main → dev 동기화 후 운영 데이터 복원 커밋 필요
- hook 차단은 `exit 2`만 유효 (`exit 1`은 통과됨)

---
*마지막 갱신: 2026-04-10*
