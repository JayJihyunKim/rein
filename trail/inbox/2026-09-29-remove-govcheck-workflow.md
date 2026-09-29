# 2026-09-29 — 수동 전용 governance 자가검사 워크플로 제거, 검사 단계는 테스트 CI 로 이전 (완료)

- DoD: `trail/dod/dod-2026-09-29-remove-govcheck-workflow.md` (승인 2026-09-29 "dev push 하고 govcheck는 삭제해")
- 오케스트레이션: 단독 처리 — 파일 4개(삭제 1·단계 추가 1·strip 블록 제거 1·표 한 행 1)
- 커밋: dev (본 기록과 같은 커밋). 직전 커밋 `6d6cb13`(주간 워크플로 2종 제거)은 이 작업 시작 전 push 완료.

## 배경·판단 정정

직전 기록은 `govcheck.yml` 을 "`tests.yml` 과 완전 중복" 이라고 적었으나 **정확하지 않았다**: 스크립트 스위트(`tests/scripts/test-rein-govcheck.sh`)와 통합 테스트는 `scripts/rein-govcheck.py` 를 격리 샌드박스 사본에 대해서만 돌린다. 실제 저장소 트리에 대한 실행은 이 워크플로가 유일했다(수동 전용, 2026-04-30 이후 실행 이력 없음, 실측 2026-09-29 exit 0). 그래서 워크플로는 지우되 그 한 줄을 `tests.yml` 의 단계로 옮겨 dev push/PR/발행 preflight 에서 자동 실행되게 했다 — 수동 워크플로 하나가 사라지고 검사는 승격.

## 한 것

- `.github/workflows/govcheck.yml` 삭제(32줄; permissions 블록 없음 = 저장소 기본 토큰(API 확인 결과 read)·secrets 없음·저장소 가드 있음).
- `.github/workflows/tests.yml`: `tests` 잡에 `Run governance self-test`(`python3 scripts/rein-govcheck.py`) 단계 추가 — 도구 버전 출력 다음·훅 테스트 앞, 첫 실질 단계라 `if: !cancelled()` 없이(실패하면 잡 실패, 뒤 단계 기본 skip). 매트릭스·권한·트리거 무변경.
- `.github/workflows/mirror-to-public.yml`: govcheck strip 블록 제거(strip 블록 5→4). 다른 블록·push·postcondition 무변경.
- `.claude/rules/branch-strategy.md`: main 포함 표에서 govcheck 행 제거 + 인용문에 이전 사실 한 문장. 남은 워크플로 5개(mirror-to-public·publish-plugin·tests·issue-triage·plugin-drift-check)와 표 일치.

## 검증

- 기준서 검증 기준 8항목 통과(추적 0·미러 참조 0·tests.yml 명령 1·YAML 2종 파싱·strip 4·규칙 문서 참조 0·실저장소 자가검사 exit 0·미러 구조/CI 매트릭스 테스트 OK).

## 리뷰

- 코드 리뷰(codex, 산출 high): 1회차 통과·기록 발급. 새 단계 위치·실패 의미(잡 실패, `!cancelled()` 단계들은 계속) 확인. 지적 없음.
- 보안 리뷰(standard): 통과·기록 발급. 커밋 대상 워크플로 3파일 모두 지문에 포함(stage 후 캡처). `rein-govcheck.py` 전문 확인 — read + `ast.parse` + `bash -n`, 네트워크·쓰기·env 읽기 없음. 공개 저장소에 govcheck.yml 부재 확인(404). **main 반영 주의 동일**: main 에는 govcheck.yml 이 아직 있으므로 미러 변경과 `git rm` 을 같은 커밋에(직전 두 파일과 합쳐 총 3파일).

## 후속 후보

- 직전 기록의 나머지 그대로: 경계 테스트 `tests/scripts/test-rein-check-plugin-drift-boundary.sh` 를 run-all 에 편입 후 `plugin-drift-check.yml` 삭제 · `issue-triage.yml` 버그 안내 문구 현행화 · `repo-audit` 스킬 본문 · 스킬 스위트 회차 예산 테스트 정체.
- CI 과금 복구 후 첫 dev push 런에서 새 governance 단계가 실제 러너에서 통과하는지 확인(로컬은 통과, 호스티드 실행은 미재현).
