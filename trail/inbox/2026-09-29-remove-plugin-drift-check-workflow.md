# 2026-09-29 — 수동 전용 drift 검사 워크플로 제거, 경계 테스트 수리·편입, 실저장소 drift 검사 CI 이전 (완료)

- DoD: `trail/dod/dod-2026-09-29-remove-plugin-drift-check-workflow.md` (승인 2026-09-29 "plugin-drift-check도 정리해")
- 오케스트레이션: 단독 처리 — 파일 6개
- 커밋: dev (본 기록과 같은 커밋). 같은 날 선행: `6d6cb13`(주간 2종), `5618f0a`(govcheck).

## 배경·발견

`plugin-drift-check.yml` 은 수동 전용, 4월 30일 이후 실행 없음. 하던 일 3가지 중 drift 스크립트 실행은 발행 preflight(태그 push 때만)에, detection 테스트는 run-all 에 이미 있었고, **경계 테스트(`tests/scripts/test-rein-check-plugin-drift-boundary.sh`)만 이 워크플로가 유일한 실행 경로**였다. 그런데 그 테스트가 로컬에서 **pass 6 / fail 2** (T2·T3). 원인은 테스트 코드가 아니라 환경: 검사 스크립트 출력은 정상(위반 7건)인데, 줄을 세는 `grep -c '^BOUNDARY:.*\.md$'` 가 **GNU grep 3.7(Ubuntu 22.04) + UTF-8 로케일**에서 메시지 속 한글 "해야" 를 가로지르는 `.*` 를 못 맞춰 0 을 돌려준다. 최소 재현 `printf 'B 해야 md\n' | LC_ALL=en_US.UTF-8 grep -c 'B.*md'` → 0, `LC_ALL=C` → 1 ("만"·"보유" 는 통과, "해야" 만 실패 — grep 3.7 DFA 결함으로 추정, 3.11 러너는 미확인). 워크플로가 한 번도 돌지 않아 아무도 못 봤다.

## 한 것

- 경계 테스트: T2 `grep -c`·T3 `grep -q` 에 `LC_ALL=C` 고정 + 지속 계약 주석. **리뷰 1회차 High 반영**: T8(dev-only 규칙 4 파일 정확 일치)이 `.claude/rules/` 부재 트리(main — 정책상 오버레이 제외)에서 공허 성립으로 통과하도록 분기 — 이 묶음이 이제 main 기반 태그 발행 preflight 에서도 돌기 때문. 디렉토리가 있으면 기존 정확 일치(잡파일 음성 케이스 보존).
- `tests/scripts/run-all.sh` 에 경계 테스트 편입.
- `.github/workflows/tests.yml` 에 `Run plugin drift check`(`python3 scripts/rein-check-plugin-drift.py`) 단계 추가 — governance 단계 다음. dev push 에서 실저장소 drift 검사가 도는 유일한 자리.
- `.github/workflows/plugin-drift-check.yml` 삭제. 미러 strip 블록 제거(4→3). 브랜치 규칙 표 행 제거 + 인용문 한 문장. 남은 워크플로 4개: mirror-to-public·publish-plugin·tests·issue-triage.

## 검증

- 경계 테스트 dev 8/8, `git archive main` 스냅샷 8/8(T8 공허 경로), 스냅샷에 잡파일 추가 시 T8 만 실패(7/1). main 스냅샷에서 tests.yml 새 단계 2개(governance·drift) exit 0. 미러 구조·CI 매트릭스 테스트 OK, YAML 파싱, bash -n.

## 리뷰

- 코드 리뷰(codex, high): **1회차 NEEDS-FIX** — High 1: 편입한 경계 테스트의 T8 이 main 트리에서 실패해 태그 발행 preflight 를 막음(리뷰어가 main 스냅샷에서 재현). 위 분기로 수정. **2회차 통과·기록 발급.** Low 잔여: T8 부재 분기는 dev 에서 디렉토리 통째 삭제도 통과시킴(공유 규칙 미러 불변식은 T7 이 독립 검증). 요청서 사전검사 거부 1회(문장 속 "실패" 결과 서술어 — 고쳐 씀).
- 보안 리뷰(standard): 통과·기록 발급(지문에 비문서 5파일 모두 포함). drift 스크립트가 훅 5개를 subprocess 로 실행하지만 env 를 5개 변수로 새로 구성해 러너 토큰이 훅에 전달되지 않음 확인. **main 반영 제약 확대**: main 에는 오늘 지운 워크플로 4개가 아직 있고 dev 의 새 미러에는 그 strip 블록이 없다 → main 반영 커밋에 **4파일 `git rm` 과 미러 변경을 반드시 한 커밋에**. 특히 `repo-audit`·`weekly-agent-evolution` 은 schedule 트리거라 공개 저장소에서 실제로 돌 수 있음.

## 후속 후보

- `issue-triage.yml` 버그 안내 문구(폐기된 INC-NNN 경로) 현행화 · `repo-audit` 스킬 본문 · 스킬 스위트 회차 예산 테스트 정체 · CI 과금 복구 후 새 단계 2개 러너 확인.
- 검사 스크립트 출력 메시지가 한글을 포함해 셸 테스트가 로케일에 민감 — 다른 셸 테스트에서 같은 패턴(`grep .*` + 한글 메시지)이 있는지 점검.
