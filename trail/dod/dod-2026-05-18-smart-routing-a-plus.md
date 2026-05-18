# DoD — 스마트 라우팅 A+ (인벤토리 스캐너 폐기 + routing-procedure 강화)

- 날짜: 2026-05-18
- 유형: refactor + docs

## 목표

스마트 라우팅의 인벤토리 스캐너 서브시스템을 폐기하고, 라우팅을 Claude Code 가
매 세션 주입하는 skill/agent/MCP 목록(authoritative source)에 기반하도록 전환한다.
발견·매칭 알고리즘을 dev-only `.claude/orchestrator.md` 에서 plugin 배포본
`plugins/rein-core/rules/routing-procedure.md` 로 이식해 plugin self-contained 화한다.

근거: 본 세션 tradeoff 검토 + `/codex-ask` (gpt-5.5, high) 독립 검토 — 둘 다
Option A+ 로 수렴. 스캐너는 (a) Claude Code 의 비문서화 plugin 저장 레이아웃에
결합돼 빈 결과만 내고 (b) 세션이 이미 주입하는 enabled capability 목록의 불완전한
복제본이며 (c) MCP runtime instruction 을 못 봐 세션보다 정보가 적다.

## 완료 기준

### Task 1 — routing-procedure.md 강화 (THICKEN)
- `.claude/orchestrator.md` 의 "스마트 라우팅 절차" (동적 발견 / 신호 추출 /
  매칭 / 조합 생성 / 사용자 확인) 를 `routing-procedure.md` 로 이식.
- 발견 source 를 "Claude Code 가 세션 컨텍스트에 주입하는 skill/agent/MCP 목록"
  으로 명시 (디스크 스캔 아님).
- 정적 "기본 권장 조합표" 를 routing-procedure.md 정적 섹션으로 포함.
- SKILL.md 본문 blanket pre-scan 금지 — 특정 skill 선택 후 progressive
  disclosure 로만 읽음을 명시.

### Task 2 — 스캐너 서브시스템 폐기 (DELETE + DEWIRE)
- 삭제: `rein-scan-skill-mcp.py` ×2 (plugin + repo scripts/),
  `rein-generate-skill-mcp-guide.py` ×2.
- `session-start-load-trail.sh` 의 `BEGIN D skill-mcp ~ END D skill-mcp` 블록
  + SCAN/GEN helper resolve + `emit_skill_guide`/`skill_scan_needed` 제거.
- `pre-edit-dod-gate.sh` 의 `SKILL_REGEN_STAMP` 블록 제거.
- `rein-state-paths.py` 의 `inventory` / `skill-mcp-guide` 서브커맨드 제거.

### Task 3 — 테스트 정리
- 삭제: `tests/hooks/test-skill-mcp-inventory.sh`,
  `tests/scripts/test-state-path-inventory-plugin.sh`.
- `tests/hooks/run-all.sh` 에서 삭제 테스트 엔트리 제거.
- `tests/scripts/test-plugin-scripts-bundle.sh` 의 expected bundle 목록에서
  삭제 스크립트 2종 제거.
- `test-session-end-stamp.sh` / `test-session-start-tone.sh` 의 skill-mcp
  의존 여부 조사 후 정리.

### Task 4 — 문서 갱신
- `.claude/CLAUDE.md` 로딩 순서에서 "skill/MCP 인벤토리 가이드" 항목 제거.
- `.claude/rules/branch-strategy.md` ✅포함 표에서
  `rein-generate-skill-mcp-guide.py` 행 제거.
- `AGENTS.md` 의 skill-mcp 참조 조사 후 정리.
- `orchestrator.md` 위상 정리 — routing-procedure.md 가 라우팅 SSOT 가 되므로
  orchestrator.md 의 guide 참조 제거 (dev-only 파일 자체는 유지 가능).

### 공통 완료 기준
- `tests/hooks/**` 전체 회귀 `ALL SUITES PASSED`
- codex review + security review 통과

## 범위 메모

> `## 범위 연결` 섹션은 두지 않는다 — plan 의 work unit 구현이 아니라 본 세션
> tradeoff 검토 + codex-ask 로 수렴한 refactor 라 coverage matrix 대상이 아니다.

plan: 없음 (N/A). design = 본 세션 다중 라운드 tradeoff 검토 + `/codex-ask`
gpt-5.5 high 독립 검토 → Option A+ 수렴. 별도 design/plan 문서 없음.
versioning: SessionStart 주입 동작 변화 → user-facing. versioning.md Rule A
patch 등급 — 단 미릴리즈 v1.3.1 에 동승 가능 (별도 bump 불요).

## 라우팅 추천

```yaml
agent: rein:feature-builder
skills: []
mcps:
  - serena  # opportunistic — 폐기 대상 dewire 시 심볼/참조 내비게이션 필요할 때만
rationale: >
  스캐너 서브시스템 삭제 + 4개 hook/script dewire + routing-procedure.md
  콘텐츠 이식 + 테스트/문서 정리 — 기존 모듈 제거·변경이라 feature-builder.
  설계는 codex-ask 로 이미 수렴, 신규 TDD 불요 (테스트는 삭제·갱신 위주).
  실행: 2-agent 병렬 분할 — Agent A = Task 1 (routing-procedure.md THICKEN,
  write 대상은 routing-procedure.md 만), Agent B = Task 2~4 (폐기/dewire/
  테스트/문서 — 그 외 전부). Task 2↔3 은 hook 변경↔테스트 갱신이 coupled 라
  한 에이전트(B)로 묶음. 두 에이전트는 write-disjoint 라 동시 dispatch.
  codex+security review 는 통합 후 전체 changeset 1회.
approved_by_user: true  # 2026-05-18 사용자 승인 — A+ 진행 + 병렬 에이전트 분할
```
