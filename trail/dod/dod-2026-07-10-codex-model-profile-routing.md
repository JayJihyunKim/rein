# DoD — Codex 모델 프로필 라우팅 (역할 기반 유연 적용)

작성일: 2026-07-10
slug: codex-model-profile-routing

## 범위 연결

plan ref: docs/plans/2026-07-10-codex-model-profile-routing.md
covers: [MP1-config-source-exposes-scalar-profiles, MP1-legacy-alias-tracks-new, MP2-canonical-fallback-on-config-absent, MP3-risk-floor-promotes-low-to-medium, MP3-marker-overrides-floor, MP3-spec-mode-floor-skipped, MP4-stamp-evidence-fields-additive, MP4-commit-gate-parser-unbroken, MP5-ultra-max-xhigh-rejected-with-reason, MP5-auto-vocab-low-medium-high-only, MP6-ask-three-tier-selection, MP7-review-skill-profile-sync, MP8-mirror-byte-identical, MP9-behavioral-suite-covers-routing-contracts]

## 배경 / 동기

codex CLI 0.144.1 업데이트로 모델 라인업이 gpt-5.6 세대(sol/terra/luna)로 재편되고 effort 단계가 xhigh/max/ultra 까지 확장됐다. 현재 설정(`codex-models.sh` = gpt-5.5 양 역할 고정)은 동작하지만 한 세대 뒤처짐. `/codex-ask`(gpt-5.6-sol, 공식 docs 대조) 독립 의견: **규모 기반 모델 라우팅은 반대(심사위원 셋 운영 = 판정 비일관), 역할 기반 프로필 분리는 찬성**. 게이트=sol 고정+effort 가변, second opinion=fast/default/deep 3계층(luna/terra/sol). 추가 권고: 게이트 도장에 모델·effort 증빙 부재 해소, 변경 크기≠위험도 → 위험도 하한선(floor), ultra 게이트 금지, config 부재 시 무모델 degrade 의 게이트 모순 해소. 사용자가 권고 전체 채택을 승인(2026-07-10 세션).

## 범위

### IN
- **P1 (config 프로필 구조)**: `plugins/rein-core/config/codex-models.sh` 재구성 — `CODE_GATE_MODEL="gpt-5.6-sol"`, `CODE_FAIL_CLOSED_MODEL="gpt-5.6-sol"`/`CODE_FAIL_CLOSED_EFFORT="high"`, `ANALYSIS_FAST_MODEL="gpt-5.6-luna"`/`ANALYSIS_DEFAULT_MODEL="gpt-5.6-terra"`/`ANALYSIS_DEEP_MODEL="gpt-5.6-sol"` + 각 effort, `CODE_ROUTING_POLICY_VERSION="1"`. **legacy alias 유지**: `CODE_MODEL`/`ANALYSIS_MODEL`/`CODE_EFFORT`/`ANALYSIS_EFFORT` 를 새 변수값으로 정의(기존 소비자 무중단). 실행 side-effect 없는 scalar 변수만.
- **P2 (래퍼 canonical fallback)**: `rein-codex-review.sh` — config 로드 실패(전 후보 부재) 시 현행 "빈 모델 → codex 기본 모델 degrade" 를 폐지, 래퍼 내장 canonical 상수(`gpt-5.6-sol`+`high`)로 명시 폴백 + stderr 경고. 게이트 예측 가능성 확보(hard-fail 대신 가용성 보존 — codex 권고 양안 중 후자).
- **P3 (위험도 하한선)**: 산출 effort 에 path 기반 floor 적용 — 변경 파일 중 `hooks/**`, `scripts/rein-*.sh`, `security/**`, `config/**`, `.github/workflows/**` 매칭 시 산출이 `low` 면 `medium` 으로 승격(`high` 는 유지). **마커 오버라이드는 floor 위에 있음**(E5 재승급 불변식 보존 — 마커 > floor 적용된 산출). spec 모드(문서 리뷰)는 floor 미적용(코드 경로 아님).
- **P4 (도장 증빙)**: code-review PASS 도장에 실행 증거 필드 추가 — `model:`, `effort:`, `effort_source:` (`marker`|`computed`|`computed+floor`|`fail_closed`), `policy_version:`, `codex_version:`. 기존 필드 보존(additive). 게이트 파서(`pre-bash-test-commit-gate.sh`)가 신규 필드에 비의존임을 확인.
- **P5 (ultra/max/xhigh 마커 거부)**: `[EFFORT:ultra|max|xhigh]` → 기존 무효값 경로(산출 진입)로 처리하되 **구체적 거부 사유 메시지** 분리(ultra=자동위임 게이트 금지, max/xhigh=timeout 실측 전 미지원). 자동 산출 어휘는 `low|medium|high` 유지.
- **P6 (codex-ask 3계층)**: `skills/codex-ask/SKILL.md` — 호출자가 질문 성격으로 fast(기계적 추출·분류)/default(일반 second opinion)/deep(고위험·모호 판단) 프로필 선택, 각 `ANALYSIS_*_MODEL`/`_EFFORT` 사용. ultra 는 게이트 금지 + codex-ask 에서도 기본 미사용(사용자 명시 요청시에만, 도장 생성 금지 불변).
- **P7 (codex-review SKILL 동기화)**: `skills/codex-review/SKILL.md` — 모델 단일출처 서술(프로필 구조), 도장 필드 규격(§5.1) 확장, ultra 거부, canonical fallback, 위험도 floor 서술. exit 3 모델 fail-soft 안내의 변수명 갱신.
- **P8 (미러)**: `scripts/rein-codex-review.sh`(루트 사본) byte-identical 동기화.
- **P9 (테스트)**: 신규 행위 테스트 — 프로필 로드/legacy alias, config 전부 부재 → canonical fallback(빈 모델 아님), floor 승급(hooks 경로 low→medium, high 유지, 마커 우선), 도장 증빙 필드 존재, ultra/max/xhigh 마커 거부 메시지 + 산출 진입. 기존 codex-review 회귀 GREEN.

### OUT
- terra/luna **그림자 평가**(게이트 모델 교체 검증): 후속 — 결함 코퍼스 비교 측정 별도 세션.
- `xhigh` 마커 **허용**: 후속 — timeout 실측 후 명시적 재승급 전용으로 재검토.
- `[MODEL:]` 마커 구현: codex 권고대로 게이트에서 금지 유지(prompt-controlled downgrade 경로). 미구현 유지.
- `REIN_*_PROFILE_OVERRIDE` 환경변수 오버라이드: 필요성 미확인, 후속.
- 줄수 경계(≤10/≤100 등) 재조정: sol 실측 후.
- `~/.codex/config.toml` 변경: 사용자 환경 불가침 유지.

## 변경 파일
- plugins/rein-core/config/codex-models.sh
- plugins/rein-core/scripts/rein-codex-review.sh + scripts/rein-codex-review.sh (2사본 byte-identical)
- plugins/rein-core/skills/codex-review/SKILL.md
- plugins/rein-core/skills/codex-ask/SKILL.md
- tests/skills/test-codex-model-profile-routing.sh (신규) + tests/skills/run-all.sh 등록
- tests/skills/test-codex-model-failsoft.sh — T4 assert 갱신 (구계약 "config 부재 → `-m` 생략" 이 P2 에서 폐지됨 → canonical `-m gpt-5.6-sol` 전달 계약으로 교체. 구현 중 발견된 구계약-신계약 충돌 해소, 2026-07-10 통합 리뷰 R1 지적 반영)

## 검증 기준
- plan coverage 매트릭스 P1~P9 전부 충족(파일·계약·테스트 이진 판정).
- config 정상 로드 시 게이트 모델 = `gpt-5.6-sol`, legacy `CODE_MODEL`/`ANALYSIS_MODEL` 도 신값 노출.
- config 전 후보 부재 시 codex 호출에 `-m gpt-5.6-sol` + effort `high` 적용(무모델 호출 0건) + stderr 경고 1회.
- hooks/ 경로 1파일 5줄 변경 → 산출 low 가 medium 으로 승격. 100줄+ 다중파일 → high 유지(floor 무영향). `[EFFORT:low]` 마커 + hooks 경로 → 최종 low(마커 > floor). spec 모드 → floor 미적용.
- PASS 도장에 model/effort/effort_source/policy_version/codex_version 5필드 존재 + 기존 필드 보존, 커밋 게이트 회귀 GREEN.
- `[EFFORT:ultra]` → ultra 전용 거부 메시지 + 산출 진입(codex 로 ultra 미전달). max/xhigh 동일 경로 + 각자 메시지.
- 미러 diff 빈 출력 + 번들 테스트 GREEN.
- SKILL 2종에서 gpt-5.5 단일모델 서술 부재, 3계층/floor/증빙/ultra 금지 서술 존재.
- 신규 테스트 + 기존 회귀 GREEN, codex 코드 리뷰 PASS + 보안 리뷰 PASS.

## 라우팅 추천

agent: rein:parallel-execute (plan 실행 전략 — Wave 1 병렬 edit_only[test-first·config-edit·skill-doc-edit×2] → Wave 2 단독[wrapper-impl, 단일파일·TDD 의존] → Wave 3 단독[mirror-sync, wrapper 의존], 각 worker = feature-builder)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - 직전 사이클(effort 결정론 산출)과 동형의 brownfield 래퍼 변경 + 문서 동기화 + 신규 테스트 → 동일 웨이브 구조 재사용
  - 보안 표면 = 리뷰 게이트 동작 변경(모델/effort/floor 가 리뷰 깊이 결정) + 도장 스키마 확장 → security_tier standard, 통합 보안 리뷰 필수
  - 설계는 codex-ask(gpt-5.6-sol) 독립 의견 + 사용자 전체 채택으로 수렴 완료 → spec/plan 은 형식화 단계

approved_by_user: true
