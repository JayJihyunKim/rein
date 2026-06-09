# DoD — codex-review wrapper 결함 6건 수정 (drift sync + config/exit-code/verdict/changed-files/claim-sources/라벨)

작성일: 2026-06-09
slug: codex-review-wrapper-sync

## 배경 / 동기

`test-plugin-scripts-bundle.sh` 가 `rein-codex-review.sh` 의 두 사본 sha256 drift 로 실패(`FAIL[b]: sha256 drift`). 진단:
- **plugin 사본** `plugins/rein-core/scripts/rein-codex-review.sh` = 최신(`fa3fae8`, v1.4.6 "codex 모델 단일 출처 + 모델 거부 fail-soft"). CODE_MODEL 로드 + `_detect_model_error` + `_emit_model_failsoft` + exit 3 fail-soft 포함.
- **루트 fallback 사본** `scripts/rein-codex-review.sh` = stale(`0e91991`, 2026-05-29). v1.4.6 의 fail-soft 갱신이 **누락**.

즉 v1.4.6 작업에서 plugin 사본만 갱신하고 루트 fallback 동기화를 빠뜨린 기존 결함. 페르소나 작업과 무관.

**codex 리뷰(Round 1)가 추가 결함 발견 — 단순 byte-identical 복제는 부족**: plugin 사본의 config 로드가 `$_script_dir/../config/codex-models.sh` 단일 경로다. 두 사본을 byte-identical 로 맞추면 루트 사본은 `scripts/../config/codex-models.sh`(repo 루트의 `config/`)를 찾는데 **부재**(SSOT 는 `plugins/rein-core/config/`에만 존재) → 루트 실행 시 CODE_MODEL 로드 실패 → 모델 단일출처 상실(codex 기본 모델로 silent degrade). 즉 byte-identical 자체가 location-sensitive regression 을 옮긴다. 근본 해결 = 두 사본의 config 로드를 **다중 경로 시도(location-agnostic)** 로 보강해 양쪽(plugin/root) + 설치 사용자(CLAUDE_PLUGIN_ROOT) 어디서 실행해도 SSOT 를 찾게 한다. 사용자 결정(2026-06-09): 경로 해석 보강(근본).

**codex 리뷰(Round 2)가 wrapper 의 기존 버그 2건 추가 발견** (우리 변경 밖, fa3fae8 기존 코드):
- **(B2) exit-code 누수**: `if ! CODEX_OUT=$(...); then CODEX_RC=$?` 구조에서 `$?` 가 `! CMD`(항상 0)를 캡처 → codex 비모델 호출 실패에도 `exit "$CODEX_RC"` = `exit 0`. codex 실패가 성공으로 위장.
- **(B3) verdict 파서 first-match 결함**: `_parse_verdict` 가 `grep ... | head -1` 로 **첫** FINAL_VERDICT 채택(A-LowPrio 2026-05-23 의도적 설계). codex 가 본문에 코드/예시의 FINAL_VERDICT(예: 테스트 stub `FINAL_VERDICT: PASS'`)를 인용하면 그 앞쪽 노이즈를 결론으로 오인 → 실제 결론(응답 끝, envelope 규칙 "끝에 FINAL_VERDICT")을 놓침. 실측: 본 cycle Round 2 리뷰가 NEEDS-FIX 였으나 stamp 가 PASS 로 오생성. 사용자 결정(2026-06-09): tail-match 전환 + 기존 first-match 테스트를 last-match 의도로 갱신.

## 범위

### IN
- **(B1) config 경로**: plugin 사본 config 로드를 단일 경로 → **다중 경로 시도**로 보강: `$_script_dir/../config/`(plugin 레이아웃) → `$_script_dir/../plugins/rein-core/config/`(repo 루트 fallback) → `${CLAUDE_PLUGIN_ROOT:+...}/config/`(설치 사용자). 첫 readable 후보에서 source + break.
- **(B2) exit-code**: `if ! CMD; then RC=$?` → `CMD; RC=$?; if [ "$RC" -ne 0 ]` 로 교체해 codex 실제 exit code 전파(모델에러 exit 3 fail-soft 분기는 보존).
- **(B3) verdict 파서**: `_parse_verdict` 의 `head -1` → `tail -1`(codex 응답 끝의 진짜 결론 채택). 기존 `test_parse_verdict_multiple_final_verdict_lines_first_match_wins` 를 last-match 의도로 갱신(PASS 먼저/REJECT 끝 → REJECT 채택, 보수적).
- **(B4) stale review context**: `_changed_files`(line 305)가 `DIFF_BASE..HEAD`(이미 커밋된 무관 범위)를 우선해 staged 변경을 못 봄(주석 의도는 "--cached first" 였으나 코드가 반대). working tree(staged ∪ unstaged) 우선 → 비면 committed range degrade 로 수정. rein 리뷰-후-커밋 흐름에서 staged 를 정확히 리뷰. 통합 리뷰 Round 1(B4 발견)에서 codex 가 짚음(이번 cycle 리뷰가 wrapper 변경 대신 페르소나 파일을 리뷰하던 증상).
- **(B5) claim_sources stale**: `_claim_sources`(line 570)가 `PR env > HEAD commit > DoD` 순서라, staged 리뷰에서 HEAD(거의 항상 이전 무관 커밋)를 claim 기준으로 삼는 구조적 결함(false NEEDS-FIX + staged claim 미반영으로 **false PASS 도 가능** — codex-ask 지적). 드문 self-review 만의 문제가 아니라 staged 리뷰 일반의 구조적 결함.
- **(B6) 라벨 misleading**: changed_files 슬롯 라벨이 `(${DIFF_BASE}..HEAD)`(line 867) 하드코딩 — working tree 내용일 때도 committed range 로 표시.
- **(B5/B6) 리뷰 대상 모드(review subject) 일관성 — 처리 방향 D (codex-ask 2026-06-09 권고)**: `working_tree`(staged∪unstaged 있음)/`commit_range`(clean)/`spec`(spec-review) 모드를 한 번 결정하고 (a) `_claim_sources` 가 working_tree 모드면 HEAD commit 대신 DoD 기준(PR env 최우선 유지), (b) changed_files 라벨이 모드 반영, (c) freshness 가 그 claim source 따름. B7+ 같은 stale-context 재발 차단. B1~B4 는 보존(되돌림은 검증된 치명 결함 되살림이라 과함).
- 루트 `scripts/rein-codex-review.sh` 를 보강된 plugin 사본에 byte-identical 동기화(B1~B6 반영).
- reproduction-first: B2·B3·B4·B5·B6 각각 failing test 선작성 → fix → green.
- broader staged-review 전면 재설계(모든 envelope 슬롯의 리뷰 대상 일관성)는 본 cycle 범위 밖 — 별도 후속 brainstorm/spec 등록.

### OUT
- 다른 helper 스크립트 사본 점검 — test 가 11개 helper 검사 중 codex-review.sh 만 drift, 나머지는 통과. 본 cycle 은 codex-review.sh 한정.
- fail-soft 로직(`_detect_model_error`/`_emit_model_failsoft`/exit 3) 자체 재설계 — exit-code 캡처 구조만 수정, 모델에러 분기 동작 보존.
- 루트에 별도 `config/codex-models.sh` 사본 추가 — 기각(동기화 부채 증가). 경로 보강으로 단일 SSOT 유지.
- verdict 파서를 정교한 인용-제외 파싱으로 재설계 — 기각(복잡도·취약점 증가). tail-match + envelope "끝에 FINAL_VERDICT" 규칙 일치로 충분.

## 변경 파일
- plugins/rein-core/scripts/rein-codex-review.sh (B1 config 다중 경로 + B2 exit-code + B3 verdict head→tail + B4 changed_files working-tree 우선 + B5 claim_sources review-subject 분기 + B6 라벨 모드 반영)
- scripts/rein-codex-review.sh (보강된 plugin 사본에 byte-identical 동기화)
- tests/skills/test-codex-review-wrapper.sh (B2·B3·B4·B5·B6 reproduction test 추가 + 기존 first-match 테스트 last-match 갱신)

## 검증 기준
- `diff scripts/rein-codex-review.sh plugins/rein-core/scripts/rein-codex-review.sh` 빈 출력(byte-identical).
- **(B1) 양쪽 위치 config 로드 작동**: plugin 위치·repo 루트 위치 양쪽에서 CODE_MODEL 이 `gpt-5.5`로 로드됨(시뮬레이션 확인).
- **(B2) exit-code 전파**: fake codex 가 비모델 실패(exit≠0) 시 wrapper 가 동일 non-zero exit(현재 버그=exit 0). reproduction test red→green.
- **(B3) verdict tail-match**: 본문 앞에 인용 `FINAL_VERDICT: PASS` + 끝에 실제 `FINAL_VERDICT: NEEDS-FIX` → wrapper 가 NEEDS-FIX(exit 1) 채택(현재 버그=PASS exit 0). reproduction test red→green. 갱신된 multiple-verdict 테스트(last-match) 통과.
- **(B4) staged 우선 review context**: 무관 파일 커밋(DIFF_BASE..HEAD non-empty) + 실제 변경 staged → changed_files 슬롯에 staged 포함 + 무관 커밋 미포함. working tree clean(PR 흐름)이면 committed range degrade. reproduction test 2개 red→green.
- **(B5) claim_sources 모드 일관성**: working_tree 모드(무관 HEAD 커밋 + staged 변경) 시 claim_sources 가 HEAD commit 메시지가 아니라 DoD 기준을 사용(이전 무관 커밋의 claim 오염 차단). reproduction test red→green.
- **(B6) 라벨 모드 반영**: working_tree 모드 시 changed_files 슬롯 라벨이 committed range 가 아니라 working tree 를 표시. reproduction test red→green.
- `bash tests/scripts/test-plugin-scripts-bundle.sh` 통과(11 helpers mirrored sha256-identical).
- `bash -n` 양쪽 사본 구문 통과.
- `bash tests/skills/test-codex-review-wrapper.sh` 전체 통과(B2·B3 신규 + 기존 회귀 0) + `bash tests/skills/test-codex-model-failsoft.sh` 회귀 0.
- tests/scripts 전체 스위트 ALL PASS.
- codex 코드 리뷰 PASS(Round 1 config / Round 2 exit-code+verdict → 보강 → 재리뷰).

## 라우팅 추천

agent: 직접 편집 (메인 세션 — 검증된 plugin 사본의 byte-identical 복제, reproduction = test red→green)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - drift sync(B1 config)로 시작했으나 codex 2 round 가 게이트 인프라의 기존 버그 2건(B2 exit-code 누수 / B3 verdict first-match 오인) 추가 발견 → scope 확대
  - B2·B3 는 codex-review 게이트 무결성에 직결(실패 위장 / 잘못된 PASS stamp). reproduction-first(failing test 선작성)로 증상 고정 후 수정
  - 게이트 인프라 로직 수정 + 기존 설계(first-match) 의도 변경이라 complexity medium, standard 보안 보수 적용
approved_by_user: true
