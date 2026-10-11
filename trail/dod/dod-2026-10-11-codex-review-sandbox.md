# DoD: 리뷰 래퍼가 codex 샌드박스를 명시 — 사용자 설정의 전체 권한 상속 차단

- 작성일: 2026-10-11
- plan ref: none (계획서 없는 단일 결함 수정)
- 계기: 2026-10-08 선택기 사이클 후속 — 래퍼가 `codex exec` 에 `--sandbox` 를 넘기지 않아 사용자 `~/.codex/config.toml` 의 `sandbox_mode`(이 머신 실측: danger-full-access)를 그대로 상속. SKILL 은 "기본 read-only" 라고 서술 — 문서·동작 불일치.
- 결정: 코드·문서 리뷰 모두 `--sandbox read-only` 고정. 경과: 1~3회차 코드 리뷰는 workspace-write(+하위 설정·TMPDIR 고정)로 PASS 했으나, 보안 리뷰(Medium)가 저장소 안 게이트 제어 파일(`.rein/state` 통과 기록, `.rein/policy`, `trail/dod/.review-rounds`, `.spec-reviews`, `.claude/settings.json`)이 리뷰어에게 쓰기 가능해지고 리뷰 대상 지문 밖이라 감지되지 않음, 기본 config 사용자(codex 기본 read-only)에게는 권한 확대임을 지적. 대안 `-C <빈 임시 폴더>` 는 저장소 AGENTS.md 를 codex 가 못 읽어 리뷰 기준이 바뀌므로 기각. 대가: 리뷰어는 mktemp 를 쓰는 테스트를 재실행할 수 없고(실측 codex-cli 0.161.0), 봉투 sub-item 7 대로 요청서 증거 블록을 1차 증거로 대조한다. 프롬프트 마커·환경 변수로 넓힐 수 없음.
- 등급(versioning Rule A): 리뷰어 실행 권한 축소(사용자 config 가 무엇이든 read-only) — 종료 코드·차단 범위 불변 → patch. 이번 묶음 릴리스(v2.4.1)에 포함.
- 사용자 승인: "다음 거 이어서 해 자동모드 켜고 이작업 끝까지 진행하고 릴리즈 안한것들 모아서 한번에 릴리즈해" (2026-10-11)

## 범위

IN
1. `plugins/rein-core/scripts/rein-codex-review.sh`(+ 루트 사본 `scripts/rein-codex-review.sh`) — CODEX_ARGS 에 `--sandbox read-only` 를 항상 추가.
2. `tests/skills/test-codex-model-profile-routing.sh` — 코드·문서 리뷰 모드 둘 다 `--sandbox read-only` 가 인자에 정확히 한 번, 프롬프트의 `[SANDBOX:danger-full-access]` 로 바뀌지 않음.
3. `plugins/rein-core/skills/codex-review/SKILL.md` — 샌드박스 서술을 실제 동작으로 정정.

OUT
- 리뷰어 네트워크 허용 옵션, 기존부터 로컬에서 깨진 두 스위트(effort-deterministic: 자가검증 관문 이후 미갱신·CI 목록 밖 / evidence-manifest: CI 정상·로컬 grep 차이), codex-ask 변경(이미 read-only 명시), sub-item 8 commit id, `rein job`.

## 변경 파일

plugins/rein-core/scripts/rein-codex-review.sh
scripts/rein-codex-review.sh
tests/skills/test-codex-model-profile-routing.sh
plugins/rein-core/skills/codex-review/SKILL.md

## Definition of Done

- [x] 실패 테스트 먼저 → 수정 후 통과, 기존 codex-review 스위트 회귀 없음
- [x] 코드 리뷰·보안 리뷰 통과 → 커밋 → dev 병합·push
- [x] 완료 기록·index 갱신

## 검증 기준

- 새 단언이 수정 전 실패, 수정 후 통과
- `bash tests/skills/test-codex-review-wrapper.sh`·`test-codex-model-profile-routing.sh` 등 codex-review 스위트 실패 0

## 라우팅 추천

agent: rein:feature-builder-fix
orchestration: main-session-orchestrated
worker_strategy: 인자 1줄 + 테스트 + 문서 — 강등(부모 직접). 리뷰·커밋·병합은 부모
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: low
model_hint: sonnet
effort_hint: medium
rationale:
  - 원인·수정 위치 확정, 샌드박스 모드 실측 완료
approved_by_user: true  # "다음 거 이어서 해 자동모드 켜고 이작업 끝까지 진행하고 릴리즈 안한것들 모아서 한번에 릴리즈해" (2026-10-11)
