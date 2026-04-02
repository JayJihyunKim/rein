# SOT/index.md — 현재 프로젝트 상태

> 이 파일은 5~15줄로 유지한다. 매 세션 시작 시 Claude가 읽는 유일한 상태 파일이다.
> 세션 종료 시 현재 상태로 갱신한다.

---

## 현재 상태

- **프로젝트**: claude-code-ai-native (AI-native 프로젝트 템플릿)
- **최근 완료**: hook 기반 규칙 강제화 시스템 (pre-bash-guard 강화, DoD gate 신규, blocks.log 학습 루프)
- **최근 완료**: Stitch 스킬팩 8개 도입 + MCP 설정
- **최근 완료**: SOT 운영 규칙 추가 (inbox/daily/weekly)
- **진행 중**: 없음
- **블로커**: 없음

## 주의사항

- hook 차단은 `exit 2`만 유효 (`exit 1`은 통과됨)
- Bash를 통한 파일 수정은 DoD gate를 우회함 (알려진 한계)
- Stitch MCP 사용 시 settings.local.json에 API 키 필요

---
*마지막 갱신: 2026-04-02*
