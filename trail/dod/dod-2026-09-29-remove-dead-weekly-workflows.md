# DoD: 죽은 주간 스케줄 워크플로 제거 — `weekly-agent-evolution.yml` · `repo-audit.yml`

- 작성일: 2026-09-29
- plan ref: 없음 — 파일 삭제 2 + 참조 정리 3. 설계·계획 없이 이 기준서의 수용 기준으로 닫는다.
- 사용자 지시: "그래 그럼 지워 그리고 또 쓸데없는 워크플로가 있는지 확인해봐" (2026-09-29) — 근거 질문 "Weekly Agent Evolution 이 필요한가" 에 대한 답: 2026-04 초기 스캐폴드(첫 커밋)에서 들어온 메인테이너용 주간 스케줄 2종(월요일 10:00 / 11:00 UTC, main 에서 실행, 공개 미러에서는 strip). 둘 다 읽기 전용 echo 만 하고 출력 소비자가 없다. 검사 대상은 모두 폐기된 경로다 — 사고 기록 `INC-*.md`(현재는 `auto-*.md`·`blocks.jsonl`), `.claude/agents/`·`.claude/registry/agents.yml`(2026-05~06 플러그인 SSOT 통합으로 삭제), 에이전트 후보 폴더의 유일한 파일은 05-06 기각 처리분(오탐 경고). 2026-08-05 문제 감사 보고서 §6 도 같은 지적. `repo-audit.yml` 의 유일한 실효 검사(`.env`·`secrets/` 추적 여부, exit 1)는 `.gitignore` 가 두 경로를 모두 무시하고 추적 파일 0 이며 주간 사후 점검이라 커밋을 막지도 못한다. 최근 실행 실패는 GitHub Actions 과금 문제(별건). 직전 제거 작업(2026-09-23 일일 점검 워크플로)의 완료 기록이 이 둘을 같은 기준으로 점검하라고 남겼다.

## 범위

IN
1. `.github/workflows/weekly-agent-evolution.yml` 삭제.
2. `.github/workflows/repo-audit.yml` 삭제.
3. `.github/workflows/mirror-to-public.yml` 의 두 파일 strip 블록(`if [ -f .github/workflows/repo-audit.yml ]` / `… weekly-agent-evolution.yml …` 각 6~7줄) 제거 — 존재하지 않는 파일을 strip 하는 죽은 코드. 다른 strip 블록(self·tests·publish-plugin·govcheck·plugin-drift-check·AGENTS.md·trail·.rein)은 무변경.
4. `.claude/rules/branch-strategy.md` 의 main 포함 표에서 `{repo-audit,weekly-agent-evolution}.yml` 행 제거(제거 사유는 파일명 없이 한 줄 주석으로 남긴다).
5. `plugins/rein-core/skills/repo-audit/SKILL.md` 의 triggers 에서 삭제되는 워크플로를 가리키는 "주 1회" 항목 한 줄 제거 — 수동 트리거만 남긴다. 스킬 본문의 다른 낡은 항목(레지스트리 점검 등)은 손대지 않는다.

OUT
- `govcheck.yml`(수동 전용, `tests.yml` 이 같은 스크립트를 이미 실행) · `plugin-drift-check.yml`(수동 전용, 경계 테스트의 유일한 실행 경로) · `issue-triage.yml`(공개 저장소 이슈 라벨링, 안내 문구만 낡음) 의 존폐 — 별도 판단. 이번 기록에 권고만 남긴다.
- `repo-audit` 스킬 본문 재작성(2026-08-05 감사 보고서 §7) — 별건.
- 과거 설계·계획·주간 요약·보고서·CHANGELOG 의 언급 — 역사 기록, 수정하지 않는다.
- GitHub Actions 과금 문제 — 사용자 계정 설정.
- CHANGELOG — CI 변경은 내부 전용(versioning Rule C 제외 대상). 스킬 메타데이터 한 줄 삭제는 동작·호출 방식 불변이라 docs-only 로 판정, 버전 bump 없음(Rule A "내부 전용").

## Definition of Done

- [x] 워크플로 파일 2개가 dev 에서 사라지고, 미러 워크플로에 그 파일들을 참조하는 줄이 없다
- [x] 브랜치 규칙 문서의 main 포함 표가 현존 워크플로만 나열한다
- [x] repo-audit 스킬의 triggers 가 삭제된 워크플로를 가리키지 않는다
- [x] 미러 워크플로 YAML 구문 유효, 나머지 strip 블록 수가 정확히 2 감소(7→5)
- [x] 코드 리뷰 + 보안 리뷰(`.github/workflows/**` 는 위험 경로 floor) 통과 → 커밋 → 완료 기록

## 검증 기준

- `git ls-files .github/workflows/weekly-agent-evolution.yml .github/workflows/repo-audit.yml` → 빈 출력
- `grep -c "weekly-agent-evolution\|repo-audit" .github/workflows/mirror-to-public.yml` → 0
- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/mirror-to-public.yml'))"` → exit 0
- `grep -c "git rm -q .github/workflows/" .github/workflows/mirror-to-public.yml` → 5 (삭제 전 7)
- `grep -n "weekly-agent-evolution\|repo-audit" .claude/rules/branch-strategy.md` → 빈 출력
- `grep -n "repo-audit.yml" plugins/rein-core/skills/repo-audit/SKILL.md` → 빈 출력
- `bash tests/scripts/test-mirror-workflow-q9-fix.sh` · `bash tests/scripts/test-ci-matrix.sh` · `bash tests/hooks/test-dev-only-rules-not-in-plugin.sh` 가 편집 후 트리에서 OK (미러 워크플로 구조·CI 매트릭스·규칙 경계를 다루는 기존 테스트)
- repo-audit 스킬의 frontmatter 가 YAML 로 파싱되고 `triggers` 에 수동 항목만 남는다 (`python3 -c "import yaml; ..."`). 전체 스킬 스위트는 repo-audit 스킬을 참조하는 테스트가 없어 이 작업의 검증 수단이 아니다 — 회차 예산 테스트에서 장시간 정체해 중단했고, 그 스위트 상태는 이 작업과 무관한 별도 관찰 사항으로 완료 기록에 남긴다

## 라우팅 추천

agent: rein:feature-builder-refactor
orchestration: standalone
worker_strategy: 없음 — 파일 5개, 삭제·줄 제거·표 한 행·메타 한 줄. 메인 세션 단독 처리
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # .github/workflows/** 위험 경로 — 미러 strip 목록 변경이 공개 노출 범위에 닿는지가 보안 관점
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 동작 불변의 정리(죽은 워크플로·죽은 strip 코드·죽은 참조 제거) → refactor 분류. 새 동작 없음
  - 미러 워크플로는 공개 저장소 노출 범위를 결정하므로 보안 리뷰 필수 — strip 목록에서 빠지는 것이 "이미 존재하지 않는 파일" 둘뿐임을 확인. main 선별 반영 시 삭제와 미러 변경을 같은 커밋에 넣는다(직전 보안 리뷰 참고 사항)
approved_by_user: true  # 사용자 지시 "그래 그럼 지워" (2026-09-29)

## 변경 파일

- .github/workflows/weekly-agent-evolution.yml (삭제)
- .github/workflows/repo-audit.yml (삭제)
- .github/workflows/mirror-to-public.yml
- .claude/rules/branch-strategy.md
- plugins/rein-core/skills/repo-audit/SKILL.md
- trail/inbox/2026-09-29-remove-dead-weekly-workflows.md
- trail/index.md
