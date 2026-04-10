# SOT/index.md — 현재 프로젝트 상태

> 이 파일은 5~15줄로 유지한다. 매 세션 시작 시 Claude가 읽는 유일한 상태 파일이다.
> 세션 종료 시 현재 상태로 갱신한다.

---

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **최근 완료**: Security Layer v0.2.0, Smart Router 레지스트리
- **진행 중**: 브랜치 정리 + v0.3.0 릴리즈
- **버전**: v0.2.0 → v0.3.0 준비 중
- **블로커**: GitHub 레포 리네임 수동 작업 필요 (Settings → Repository name → `rein`)

## 주의사항

- hook 차단은 `exit 2`만 유효 (`exit 1`은 통과됨)
- Bash를 통한 파일 수정은 DoD gate를 우회함 (알려진 한계)
- 테스트/커밋 시 `.codex-reviewed` + `.security-reviewed` 두 stamp 모두 필요

---
*마지막 갱신: 2026-04-10*
