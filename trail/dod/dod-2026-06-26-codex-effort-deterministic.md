# DoD — Codex 리뷰 강도(effort) 결정론적 산출

작성일: 2026-06-26
slug: codex-effort-deterministic
plan ref: docs/plans/2026-06-26-codex-effort-deterministic.md

## 배경 / 동기

codex 리뷰가 사실상 항상 `high` 로 돌아 기능 구현 체감 속도를 떨어뜨린다(실측: 자동 리뷰 61% high, high 중앙값 2분 31초 = low 의 2.9배 — `docs/reports/2026-06-26-codex-effort-measurement.md`). 근본원인은 리뷰 강도 마커 `[EFFORT:]` 를 생산하는 코드가 0건이고, 자동 경로가 마커를 안 붙여 `CODE_EFFORT=high` + `~/.codex/config.toml=high` 이중 폴백으로 결정론적 high 에 떨어지는 것. 래퍼 `rein-codex-review.sh` 가 변경 규모로 effort 를 코드로 산출하게 만든다. brainstorm → spec(codex 4R PASS) → plan(codex PASS, 13/13 커버) 체인 완료. 본 DoD 는 구현 단계를 정의한다.

## 범위

### IN
- **E1 (산출 함수)**: `rein-codex-review.sh` 신규 top-level `_compute_effort()` — `REIN_EFFORT` 빈 경우에만 호출, 변경 규모로 `low|medium|high` 출력, 측정 실패 시 빈 문자열(폴백 위임). 코드/문서/마커우선 게이팅 분기. `|| true` 가드로 `set -euo pipefail` 하 git/wc 실패가 스크립트 비차단.
- **E2 (임계값)**: 코드리뷰 — low=(≤10줄 AND ≤1파일) 또는 all-docs(확장자 화이트리스트 {md,markdown,txt,rst}); medium=≤100줄 AND ≤3파일; high=>100줄 또는 >3파일. 문서리뷰 — low≤150, medium 151–400, high>400.
- **E3 (폴백/무효마커)**: 측정 실패 → `CODE_EFFORT=high` 폴백(fail-closed). 무효 `[EFFORT:]` → strip 후 산출 진입(config high 폴백 아님) + warn 문구 갱신.
- **E4 (문서 동기화)**: `config/codex-models.sh` 주석 갱신(값 유지) + `skills/codex-review/SKILL.md` §6.1/§6.2/§6.3 "코드 산출 권위, 수동 마커=오버라이드" 재서술.
- **E5 (불변식)**: 재승급(`[EFFORT:high]`)은 마커 우선이라 산출과 독립 — SKILL 명시 + 테스트 고정.
- **E6 (미러)**: `scripts/rein-codex-review.sh`(루트 사본) byte-identical 동기화.
- **E7 (테스트)**: 신규 `tests/skills/test-codex-effort-deterministic.sh` — 산출 전 분기 행위기반(stub git/wc) + HEAD-부재 경로 + all-docs 확장자 차단. 기존 codex-review 회귀 GREEN.

### OUT
- **Option D (보안표면 접촉 시 강제 high)**: 재사용 민감경로 신호 부재(codex-ask INVALID) → 1차 제외, 후속.
- 호출자(spec-writer/plan-writer) 수정: 불필요(래퍼가 권위, 산출이 채움).
- `[MODEL:]`/`[SANDBOX:]` 마커 구현, `~/.codex/config.toml` 변경: 범위 밖.
- 임계값 자동 튜닝/학습: 고정 휴리스틱(advisory), 후속.

## 변경 파일
- plugins/rein-core/scripts/rein-codex-review.sh + scripts/rein-codex-review.sh (2사본 byte-identical)
- plugins/rein-core/config/codex-models.sh (주석만, 값 유지)
- plugins/rein-core/skills/codex-review/SKILL.md (§6.1/§6.2/§6.3 동기화)
- tests/skills/test-codex-effort-deterministic.sh (신규) + tests/skills/run-all.sh 등록

## 검증 기준
- plan 의 coverage 매트릭스 E1~E7 (Scope ID 13개) 전부 충족(파일·계약·테스트 이진 판정).
- 마커 부재 + working_tree 소형(≤10줄/≤1파일) → `low`; 대형(>100줄 또는 >3파일) → `high`.
- spec 모드 150줄 → `low`, 401줄 → `high`; spec 산출 경로 `git diff` 호출 0건.
- `[EFFORT:low]` + 대형 → 최종 `low`(마커 우선). 무효 `[EFFORT:xyz]` + 소형 → `low` + warn 1회, 마커 strip 유지.
- 측정 실패(git/wc 강제 실패 stub, spec subject 미존재) → `high`(fail-closed). HEAD-부재 경로 결정론적(빈 numstat → 빈 출력 → high), 스크립트 비차단.
- all-docs 확장자 판정 — `docs/x.sh`+`a.md` 200줄 → `high`(.sh 차단). `.md` 전용 → 줄수 무관 `low`.
- `[EFFORT:high]`(재승급) + 소형 → `high`(불변식).
- `diff plugins/rein-core/scripts/rein-codex-review.sh scripts/rein-codex-review.sh` 빈 출력 + `tests/scripts/test-plugin-scripts-bundle.sh` GREEN.
- SKILL §6.1/§6.2/§6.3 정적 high default 주장 부재 + "코드 산출 권위" 서술 존재.
- 신규 테스트 + 기존 codex-review 회귀 GREEN.
- codex 코드 리뷰 PASS + 보안 리뷰 PASS.

## 라우팅 추천

agent: rein:parallel-execute (plan 실행 전략 — Wave 1 병렬 edit_only[test-first·config-edit·skill-doc-edit] → Wave 2 단독[wrapper-impl, 단일파일·TDD 의존] → Wave 3 단독[mirror-sync, wrapper 의존], 각 worker = feature-builder)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - 기존 래퍼 동작 변경(brownfield)이며 plan 이 3-웨이브(disjoint scope 병렬 → 단일파일 단독 → 미러 의존)로 설계됨 → parallel-execute 로 웨이브 dispatch, 부모가 웨이브별 red/green·byte-identical 검증·커밋
  - 보안 표면 = 리뷰 게이트 동작 변경(effort 산출이 리뷰 깊이 결정) + git 호출 + 셸 파싱 → security_tier standard, 통합 보안 리뷰 필수
  - 단일 핵심 파일 + 문서 동기화 + 신규 테스트 → complexity medium, effort medium(우리가 진단한 교훈대로 high 회피)

approved_by_user: true
