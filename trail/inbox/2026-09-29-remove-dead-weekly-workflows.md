# 2026-09-29 — 죽은 주간 스케줄 워크플로 2종 제거 (완료)

- DoD: `trail/dod/dod-2026-09-29-remove-dead-weekly-workflows.md` (승인 2026-09-29 "그래 그럼 지워 그리고 또 쓸데없는 워크플로가 있는지 확인해봐")
- 오케스트레이션: 단독 처리 — 파일 5개(삭제 2·strip 블록 제거 1·표 한 행 1·스킬 메타 한 줄 1), 워커 불필요
- 커밋: dev (본 기록과 같은 커밋)

## 배경

사용자 질문 "Weekly Agent Evolution 이 필요한가" → 저장소 첫 커밋(2026-04 초기 스캐폴드)에서 들어온 메인테이너용 주간 스케줄 2종(월요일 10:00 / 11:00 UTC, main 에서 실행, 공개 미러에서는 strip). 둘 다 읽기 전용 echo 만 하고 출력 소비자가 없다. 검사 대상 경로는 전부 폐기됨 — 사고 기록 `INC-*.md` 명명(현재는 `auto-*.md`·`blocks.jsonl` 이라 항상 0건), `.claude/agents/`·`.claude/registry/agents.yml`(2026-05~06 플러그인 SSOT 통합으로 삭제 — 주간 감사는 매주 "레지스트리가 없다" 오탐 경고), 에이전트 후보 폴더의 유일한 파일은 05-06 기각 처리분("승인 대기" 오탐). 2026-08-05 문제 감사 보고서 §6·§7 도 같은 지적. 주간 감사의 유일한 실패 조건(`.env`·`secrets/` 추적 시 exit 1)은 `.gitignore` 가 두 경로를 무시하고(추적 파일 0) 커밋 전 보안 리뷰 게이트와 pre-bash 훅의 env 읽기 차단이 예방형으로 덮고 있어 순손실 없음. 최근 실행 실패는 GitHub Actions 과금 문제(별건, 2026-09-23 기록과 동일).

## 전체 워크플로 점검 결과 (8 → 6)

| 워크플로 | 판정 | 근거 |
|---|---|---|
| `weekly-agent-evolution.yml` | **삭제** | 위 배경 |
| `repo-audit.yml` | **삭제** | 위 배경 |
| `mirror-to-public.yml` | 유지 | main→public 미러 본체 |
| `publish-plugin.yml` | 유지 | 태그 push 시 플러그인 발행 본체 |
| `tests.yml` | 유지 | dev push/PR 테스트 CI(과금 복구 후 재가동) |
| `issue-triage.yml` | 유지 | 공개 저장소 이슈 자동 라벨링. 단 버그 안내 코멘트가 폐기된 `trail/incidents/INC-NNN.md` 경로를 안내 — 문구 현행화 후속 |
| `govcheck.yml` | 유지(권고: 삭제 후보) | 수동 실행 전용. 실행하는 스크립트를 `tests.yml` 의 스크립트 스위트가 이미 돌림 — 완전 중복. 4월 이후 수동 실행 이력 없음 |
| `plugin-drift-check.yml` | 유지 | 수동 실행 전용. drift 검사는 publish preflight 에도 있으나, 경계 테스트 `tests/scripts/test-rein-check-plugin-drift-boundary.sh` 는 이 워크플로만 실행 — `tests/scripts/run-all.sh` 편입 후 삭제 가능 |

## 한 것

- `.github/workflows/weekly-agent-evolution.yml`·`.github/workflows/repo-audit.yml` 삭제(합계 94줄; `permissions`·`secrets`·외부 호출 없던 파일 — 기본 토큰을 쥔 스케줄 잡 2개 소멸, 공격면 순감소).
- `.github/workflows/mirror-to-public.yml`: 두 파일을 strip 하던 `if [ -f … ]` 블록 2개 제거(strip 블록 7→5). 다른 블록·순서·조건·push·postcondition·mapping-ref 무변경.
- `.claude/rules/branch-strategy.md`: main 포함 표에서 두 행 제거 + 표 아래에 제거 사유 인용문(파일명 없이). 코드 리뷰 Low 지적("경고 출력만" 은 축약 과다 — 비밀 파일 검사는 exit 1 이었음) 반영해 문구 정정.
- `plugins/rein-core/skills/repo-audit/SKILL.md`: frontmatter triggers 에서 삭제된 워크플로를 가리키던 "주 1회" 항목 제거. 수동 트리거만 남음. 본문(낡은 레지스트리 점검 항목 등)은 별건.

## 검증

- 기준서 검증 기준 전 항목 통과(추적 항목 0, 미러·규칙 문서·스킬 참조 0, YAML 파싱, strip 블록 7→5, 스킬 frontmatter 파싱).
- 기존 테스트 3종 편집 후 트리에서 OK: `tests/scripts/test-mirror-workflow-q9-fix.sh`·`tests/scripts/test-ci-matrix.sh`·`tests/hooks/test-dev-only-rules-not-in-plugin.sh`.
- 전체 스킬 스위트(`tests/skills/run-all.sh`)는 이 변경과 무관(repo-audit 스킬을 읽는 테스트 없음)이라 검증 수단에서 제외. **별도 관찰**: 15개 중 4번째 `test-review-round-budget.sh` 에서 10분 이상 정체해 중단함 — 회귀인지 원래 느린 테스트인지 미판정, 후속 점검 후보.

## 리뷰

- 코드 리뷰(codex, 산출 high): 1회차 통과·기록 발급. Low 2 — 규칙 문서 인용문 축약 과다(정정함, `*.md` 는 리뷰 지문 대상이 아니라 기록 유효), `blocks.jsonl` 훅 로그 변경은 범위 무관. 요청서 사전검사 1회 거부(형식 검사 축·테스트 축 증거 블록 + 자가 diff 검토 진술 요구 — 새 계약, 다음 요청서부터 처음에 갖출 것).
- 보안 리뷰(standard): 통과·기록 발급. 공개 저장소 실측 `.github/workflows/` 에 `issue-triage.yml` 만 존재. **main 반영 주의**: main 에는 두 파일이 아직 있으므로 선별 반영 시 두 파일 `git rm` 과 미러 변경을 **같은 커밋**에(또는 삭제 선행) — 미러 변경만 먼저 가면 다음 한 번의 미러로 두 파일이 공개에 흘러감. 기록은 스테이징 상태에 결속 — 커밋 전 전 파일 스테이징 후 지문 재확인.

## 후속 후보

- `govcheck.yml` 삭제(`tests.yml` 과 완전 중복) · 경계 테스트를 `tests/scripts/run-all.sh` 에 편입 후 `plugin-drift-check.yml` 삭제 · `issue-triage.yml` 버그 안내 문구 현행화.
- `repo-audit` 스킬 본문 재작성(2026-08-05 감사 §7) 또는 폐기 판단.
- `tests/skills/test-review-round-budget.sh` 소요 시간 점검.
- 코드 리뷰 요청서 양식에 자가검증 두 축(`[axis:typecheck]`/`[axis:test]`) + `diff_self_review:` 를 기본 포함.
