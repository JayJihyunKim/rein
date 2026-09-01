---
approved_by_user: true
plan ref: docs/plans/2026-08-28-persona-selection-ui.md
---

# DoD: Persona 선택 UI 개선 + 표시 이름 현지화

/ rein:persona 선택 흐름을 최상위 3개 고정 메뉴로 재편하고, 내장 프리셋에 표시 이름
(display_name) 을 도입해 사용자 대면·시스템 컨텍스트 세 경로(목록·turn-brief·SessionStart
주입 본문)에서 영어 파일명 slug 의 자동 노출을 없앤다. brainstorm → spec(user-approved,
codex 5R) → plan(codex PASS, 5R) 관문을 통과했다.

## 범위

- **최상위 3메뉴**: `페르소나 목록` / `내 페르소나 만들기` / `페르소나 끄기`(항상 정확히 3개).
  `페르소나 목록` 선택 시에만 2단으로 프리셋을 표시 이름+요약 flat 나열(갈래 폐지).
- **표시 이름 스키마**: 내장 3종 frontmatter 에 `display_name:`(+ 선택 `display_name_en:`) —
  boss-ace=마르코/Marco Santoro, jennie=제니/Jennie, choi-haengbae=최행배. 본문 제목
  `# Persona: <slug>` → `# Persona: <display_name>`.
- **자칭 현지화**: 로더 turn-brief active_line 이 slug 대신 표시 이름/영문 alias 를 쓰고,
  persona-summary nudge 가 응답 언어 적응을 지시. 표시 이름 없는 (구)커스텀은
  `이름 없는 페르소나` + 전역 label dedup fallback.
- **라벨**: `새로 만들기`→`내 페르소나 만들기`(설명 "새 페르소나 만들기"), `끄기(중립)`→`페르소나 끄기`.
- spec §5 의 15개 Scope 를 plan 의 7 task(2웨이브)로 구현. 상세 절차·정확한 편집 블록은
  plan ref 가 권위.

## 변경 파일

- `plugins/rein-core/rules/persona/{boss-ace,jennie,choi-haengbae}.md` — frontmatter + 본문 제목
- `plugins/rein-core/scripts/rein-policy-loader.py` + `scripts/rein-policy-loader.py` — `_read_frontmatter_display` + active_line + fallback (두 사본 byte-identical)
- `plugins/rein-core/rules/short/persona-summary.md` — 언어 적응 nudge 문장
- `plugins/rein-core/skills/persona/SKILL.md` — 최상위 3메뉴 + flat 목록 + 라벨 + 생성 흐름 slug 복사 금지
- `tests/scripts/{test-persona-preset-greeting,test-policy-loader-turn-brief,test-persona-lint}.sh`, `tests/hooks/test-session-start-persona-inject.sh`, `tests/skills/test-persona-skill.sh` — 회귀

## 검증 기준

- 각 task 는 실패 테스트 먼저(RED) → 구현(GREEN).
- 웨이브별 부모 close-out: 시작 이후 델타 ⊆ scope 부분집합 검증 → 테스트(웨이브1 expected-RED
  allowlist: jennie/choi 반복 + (q)) → codex 코드리뷰 + (로더) 보안리뷰 → 리뷰 통과 후 웨이브당
  1커밋(무스코프 `<type>: 설명`).
- 최종 통합: `tests/{skills,scripts,hooks}/run-all.sh` 전부 GREEN + `rein-validate-coverage-matrix.py plan` exit 0 + byte 예산(`BUDGET_PERSONA=6000`/`BUDGET_UPS=4000`) 이내.
- 로더 두 사본 byte-identical 유지.

## 라우팅 추천

approved_by_user: true

- **병렬 실행**: `rein:parallel-execute` — plan 의 `## 실행 전략`(2웨이브: ①boss-ace/로더/lint/스킬 ②jennie/choi/persona-summary) 을 읽어 웨이브 유도.
- **워커**: `rein:feature-builder-worker`(edit_only, model sonnet) — 편집만.
- **웨이브 통합·검증·커밋**: 부모(메인 세션) 소유.
- **코드리뷰**: `rein:codex-review`(웨이브별, foreground) · **보안리뷰**: `rein:security-reviewer`(로더 파싱 표면).
