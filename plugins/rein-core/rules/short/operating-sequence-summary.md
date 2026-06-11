# Operating Sequence — quick rule

## 행동 강령

DoD → routing → implement → codex-review → security-review → fix → test → self-review → inbox → index 순서를 따른다. hook 차단 시 stderr 안내대로 이전 단계 복귀 — 게이트 우회(타임스탬프/stamp 조작, hook 비활성화) **절대 금지**, 오탐으로 보여도 멈추고 escalate. Answer-only(단순 정보·의견·tradeoff)는 skip 하되 코드 편집 의도 즉시 정상 전환. 설계는 brainstorm → spec-writer → plan-writer → 구현. 신규 DoD 필수 섹션: `## 범위` · `## 변경 파일` · `## 검증 기준` · `## 라우팅 추천`. git/릴리스 수치 권위본 = 자동 git 스냅샷.

> 전체 본문은 `${CLAUDE_PLUGIN_ROOT}/rules/operating-sequence.md` 참조.
