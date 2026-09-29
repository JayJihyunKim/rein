# DoD: 수동 전용 drift 검사 워크플로 제거 — 경계 테스트를 테스트 묶음에 편입 + 실저장소 drift 검사를 테스트 CI 단계로 이전

- 작성일: 2026-09-29
- plan ref: 없음 — 파일 삭제 1 + 테스트 편입 1 + 테스트 수리 1 + CI 단계 1 + 참조 정리 2. 이 기준서의 수용 기준으로 닫는다.
- 사용자 지시: "plugin-drift-check도 정리해" (2026-09-29). 직전 두 작업(주간 워크플로 2종·govcheck)의 후속 후보.
- 근거: `plugin-drift-check.yml` 은 수동 실행 전용(workflow_dispatch), 2026-04-30 이후 실행 이력 없음. 하는 일 3가지 — (a) `python3 scripts/rein-check-plugin-drift.py` 실저장소 실행: `publish-plugin.yml` preflight(태그 push 때만)에 있고 dev push 에는 없음. (b) `tests/scripts/test-plugin-drift-detection.sh`: `tests/scripts/run-all.sh` 가 이미 포함. (c) `tests/scripts/test-rein-check-plugin-drift-boundary.sh`: **이 워크플로만 실행** — 그리고 2026-09-29 로컬 실측 **pass 6 / fail 2** (T2·T3). 원인: 검사 스크립트 출력은 정상(위반 7건)인데 테스트가 `BOUNDARY:` 줄을 세는 `grep -c '^BOUNDARY:.*\.md$'` 가 GNU grep 3.7(Ubuntu 22.04) + UTF-8 로케일에서 메시지 속 한글("해야")을 가로지르는 `.*` 를 못 맞춰 0 을 돌려준다(`LC_ALL=C` 에선 정상, 최소 재현 `printf 'B 해야 md' | grep -c 'B.*md'` → 0). 워크플로가 한 번도 돌지 않아 아무도 못 봤다. 따라서 (c) 를 바이트 로케일 고정으로 수리해 `run-all.sh` 에 편입하고, (a) 를 `tests.yml` 단계로 승격한 뒤 워크플로를 삭제한다 — 검사는 전부 자동화되고 수동 워크플로만 사라진다.

## 범위

IN
1. `tests/scripts/test-rein-check-plugin-drift-boundary.sh`: T2 의 `grep -c` 와 T3 의 `grep -q` 앞에 `LC_ALL=C` 고정 + 지속 계약 주석(검사 메시지가 다국어 텍스트를 포함하므로 줄 매칭은 바이트 로케일로 — grep 구현·버전에 따라 UTF-8 `.*` 가 다국어 구간에서 실패). 다른 assertion 무변경. **(리뷰 1회차 High 반영)** T8(dev-only 4 파일 정확 일치)은 `.claude/rules/` 가 없는 트리(main — 정책상 오버레이 제외)에서 공허 성립으로 통과하도록 분기 — 이 묶음이 이제 태그 발행 preflight(main 기반)에서도 돌기 때문. 디렉토리가 있으면 기존대로 정확 일치 요구(잡파일 음성 케이스 유지).
2. `tests/scripts/run-all.sh`: `test-plugin-drift-detection.sh` 다음 줄에 `test-rein-check-plugin-drift-boundary.sh` 추가.
3. `.github/workflows/tests.yml`: `Run governance self-test` 다음에 `Run plugin drift check`(`python3 scripts/rein-check-plugin-drift.py`) 단계 추가. `if:` 없음(같은 이유 — 초기 실질 단계). 매트릭스·권한·트리거 무변경.
4. `.github/workflows/plugin-drift-check.yml` 삭제.
5. `.github/workflows/mirror-to-public.yml` 의 plugin-drift-check strip 블록(주석 4줄 + if 블록 3줄 + 빈 줄) 제거. 다른 strip 블록 무변경.
6. `.claude/rules/branch-strategy.md` main 포함 표의 plugin-drift-check 행 제거 + 인용문에 "수동 drift 검사 워크플로도 제거, 경계 테스트는 테스트 묶음으로, 실저장소 drift 검사는 테스트 CI 단계로" 한 문장(파일명 없이).

OUT
- `scripts/rein-check-plugin-drift.py` 본체·`publish-plugin.yml` preflight — 무변경.
- 검사 메시지의 한글 자체를 바꾸는 것 — 스크립트 출력 계약 변경이라 별건.
- `issue-triage.yml`·`repo-audit` 스킬 본문 — 별건.
- 과거 설계·계획·주간 요약·CHANGELOG 언급 — 역사 기록, 무수정.
- CHANGELOG — CI·테스트 변경은 내부 전용(versioning Rule C 제외), 버전 bump 없음.

## Definition of Done

- [x] 경계 테스트가 기본(UTF-8) 로케일에서 8/8 통과하고 `run-all.sh` 목록에 있다
- [x] `tests.yml` 에 실저장소 drift 검사 단계가 있고 YAML 유효
- [x] 워크플로 파일이 dev 에서 사라지고 미러·브랜치 규칙 표에 참조가 없다, strip 블록 4→3
- [x] 코드 리뷰 + 보안 리뷰(`.github/workflows/**` 위험 경로) 통과 → 커밋 → 완료 기록

## 검증 기준

- `bash tests/scripts/test-rein-check-plugin-drift-boundary.sh` → exit 0, `pass=8 fail=0` (환경 LANG=en_US.UTF-8 그대로)
- 같은 테스트를 `git archive main` 스냅샷에 복사해 실행 → `pass=8 fail=0` (T8 공허 성립 경로); 스냅샷의 `.claude/rules/` 에 잡파일 1개 추가 시 T8 만 실패 (음성 케이스 보존)
- main 스냅샷에서 `python3 scripts/rein-check-plugin-drift.py --quiet` · `python3 scripts/rein-govcheck.py` → 둘 다 exit 0 (tests.yml 새 단계 2개가 main 기반 preflight 에서도 통과)
- `grep -c "test-rein-check-plugin-drift-boundary.sh" tests/scripts/run-all.sh` → 1
- `grep -c "rein-check-plugin-drift.py" .github/workflows/tests.yml` → 1
- `git ls-files .github/workflows/plugin-drift-check.yml` → 빈 출력
- `grep -c "plugin-drift-check" .github/workflows/mirror-to-public.yml` → 0 ; `grep -c "plugin-drift-check" .claude/rules/branch-strategy.md` → 0
- `python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ('.github/workflows/mirror-to-public.yml','.github/workflows/tests.yml')]"` → exit 0
- `grep -c "git rm -q .github/workflows/" .github/workflows/mirror-to-public.yml` → 3
- `python3 scripts/rein-check-plugin-drift.py` (실저장소) → exit 0
- `bash tests/scripts/test-mirror-workflow-q9-fix.sh` · `bash tests/scripts/test-ci-matrix.sh` → OK

## 라우팅 추천

agent: rein:feature-builder-fix
orchestration: standalone
worker_strategy: 없음 — 파일 6개, 메인 세션 단독
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # .github/workflows/** 위험 경로 — 미러 strip 목록 + CI 단계 추가
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 죽은 테스트 수리(재현 확인 → 로케일 고정)가 포함돼 fix 분류. 재현: 수리 전 pass 6 / fail 2, 수리 후 8/8 이 곧 재현 테스트
  - 미러 strip 목록 변경은 공개 노출 범위 → 보안 리뷰. tests.yml 단계 추가는 read 권한·저장소 내 스크립트 실행이라 권한 변화 없음
approved_by_user: true  # "plugin-drift-check도 정리해" (2026-09-29)

## 변경 파일

- tests/scripts/test-rein-check-plugin-drift-boundary.sh
- tests/scripts/run-all.sh
- .github/workflows/tests.yml
- .github/workflows/plugin-drift-check.yml (삭제)
- .github/workflows/mirror-to-public.yml
- .claude/rules/branch-strategy.md
- trail/inbox/2026-09-29-remove-plugin-drift-check-workflow.md
- trail/index.md
