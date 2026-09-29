# DoD: 중복 수동 워크플로 제거 — `govcheck.yml` (실저장소 검사 한 줄은 `tests.yml` 로 이전)

- 작성일: 2026-09-29
- plan ref: 없음 — 파일 삭제 1 + 참조 정리 2 + 한 단계 이전 1. 이 기준서의 수용 기준으로 닫는다.
- 사용자 지시: "dev push 하고 govcheck는 삭제해" (2026-09-29). 직전 작업(`dod-2026-09-29-remove-dead-weekly-workflows.md`)의 점검표가 삭제 후보로 올린 항목.
- 근거: `govcheck.yml` 은 수동 실행 전용(workflow_dispatch)이며 2026-04-30 이후 실행 이력이 없다(당시 push 트리거 시절 실패 런만 남음). 하는 일은 `python3 scripts/rein-govcheck.py` 한 줄. 이 스크립트의 단위·통합 테스트는 `tests.yml` 의 스크립트 스위트(`tests/scripts/test-rein-govcheck.sh`)와 통합 스위트가 이미 돌리지만 **격리 샌드박스 사본**에 대해서만 돈다 — 실제 저장소 트리에 대한 실행은 이 워크플로가 유일했다. 2026-09-29 실측: 실저장소 실행 exit 0(무출력). 따라서 워크플로는 지우고 그 한 줄을 `tests.yml` 의 단계로 옮겨 자동 실행(dev push/PR/preflight)으로 승격한다 — 수동 전용 워크플로 하나가 사라지고 검사는 오히려 자동화된다.

## 범위

IN
1. `.github/workflows/govcheck.yml` 삭제.
2. `.github/workflows/tests.yml` 의 `tests` 잡에 단계 1개 추가 — `Run governance self-test` (`python3 scripts/rein-govcheck.py`), 도구 버전 출력 단계 다음·훅 테스트 단계 앞. `if: ${{ !cancelled() }}` 없이(첫 실질 단계) 둔다. 매트릭스·권한·트리거 무변경.
3. `.github/workflows/mirror-to-public.yml` 의 `govcheck.yml` strip 블록(주석 5줄 + if 블록 3줄 + 빈 줄) 제거. 다른 strip 블록 무변경.
4. `.claude/rules/branch-strategy.md` main 포함 표의 `govcheck.yml` 행 제거. 표 아래 인용문에 "수동 전용 governance 자가검사 워크플로도 같은 날 제거하고 검사 단계는 테스트 CI 로 이전" 한 문장 추가(파일명 없이).

OUT
- `scripts/rein-govcheck.py` 본체·그 테스트 — 무변경.
- `plugin-drift-check.yml`·`issue-triage.yml` — 별건(직전 기록의 후속 후보 그대로).
- 과거 설계·계획·주간 요약·CHANGELOG·루트 임시 노트의 언급 — 역사 기록, 무수정.
- CHANGELOG — CI 변경은 내부 전용(versioning Rule C 제외), 버전 bump 없음.

## Definition of Done

- [x] `govcheck.yml` 이 dev 에서 사라지고, 미러 워크플로·브랜치 규칙 표에 그 파일 참조가 없다
- [x] `tests.yml` 에 실저장소 governance 자가검사 단계가 있고 YAML 이 유효하다
- [x] 미러 워크플로 YAML 유효, strip 블록 수 정확히 1 감소(5→4)
- [x] 코드 리뷰 + 보안 리뷰(`.github/workflows/**` 위험 경로) 통과 → 커밋 → 완료 기록

## 검증 기준

- `git ls-files .github/workflows/govcheck.yml` → 빈 출력
- `grep -c "govcheck" .github/workflows/mirror-to-public.yml` → 0
- `grep -c "rein-govcheck.py" .github/workflows/tests.yml` → 1
- `python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ('.github/workflows/mirror-to-public.yml','.github/workflows/tests.yml')]"` → exit 0
- `grep -c "git rm -q .github/workflows/" .github/workflows/mirror-to-public.yml` → 4
- `grep -n "govcheck.yml" .claude/rules/branch-strategy.md` → 빈 출력
- `python3 scripts/rein-govcheck.py` (실저장소) → exit 0 — 옮긴 단계가 현재 트리에서 통과함을 로컬로 확인
- `bash tests/scripts/test-mirror-workflow-q9-fix.sh` · `bash tests/scripts/test-ci-matrix.sh` → OK (미러 구조·`tests.yml` 매트릭스 계약이 단계 추가로 깨지지 않음)

## 라우팅 추천

agent: rein:feature-builder-refactor
orchestration: standalone
worker_strategy: 없음 — 파일 4개, 삭제·블록 제거·행 제거·단계 1개 추가. 메인 세션 단독
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # .github/workflows/** 위험 경로 — 미러 strip 목록 + CI 단계 추가
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 동작 보존 정리(수동 워크플로 제거, 검사는 자동 CI 로 이전) → refactor. 새 외부 표면 없음
  - 미러 strip 목록 변경은 공개 노출 범위 → 보안 리뷰. tests.yml 단계 추가는 read 권한·기존 스크립트 실행이라 권한 변화 없음
approved_by_user: true  # "govcheck는 삭제해" (2026-09-29)

## 변경 파일

- .github/workflows/govcheck.yml (삭제)
- .github/workflows/tests.yml
- .github/workflows/mirror-to-public.yml
- .claude/rules/branch-strategy.md
- trail/inbox/2026-09-29-remove-govcheck-workflow.md
- trail/index.md
