# DoD: 게이트 판정 범위 결함 3건 수리 (저장소 경계·관련성·문자열 오인)

- 날짜: 2026-08-05
- slug: gate-scope-defects
- 유형: 버그 수정 (훅 게이트 오차단 — 사용자 노출 동작)
- 입력: 2026-08-04 사이클 실측 3건 (`trail/inbox/2026-08-04-review-scope-and-round-budget.md` §백로그) + 2026-08-05 읽기 전용 정찰
- 사용자 결정 (2026-08-05): ① 결함 3건을 연쇄 드리프트 재설계보다 선행 ② 미리뷰 문서 차단은 "현재 작업 관련만 차단, 무관 문서는 비차단 경고" ③ 샌드박스 git 은 "이동 대상이 리터럴로 저장소 밖일 때만 면제, 변수·불명은 차단 유지"

## 배경 — 공통 뿌리

세 결함 모두 **어휘적 판정(문자열/표식이 존재하는가)을 의미적 판정(현재 저장소·현재 작업에 실제 영향을 주는가)으로 취급**한다. 필요한 올바른 패턴은 이미 저장소에 존재한다 — 경로 소속 검사 lib(`path-containment.sh`)는 다른 3개 훅이 쓰지만 이 게이트만 안 쓰고, 절 형태 검증은 커밋 게이트 내부에 이미 있다. 발명이 아니라 **연결 누락**의 수리다.

## 범위

### 1. 결함 1 — 게이트가 저장소 밖 경로 표식까지 판정

`pre-edit-dod-gate.sh` 의 리뷰 표식 순회 2곳(pending 루프 537~583, orphan 루프 627~768)이 표식의 `path=` 를 "파일 존재" 만으로 신뢰한다. 타 저장소 문서를 가리키는 표식이 유입되면(실측: 25건) 이 저장소 편집 전체가 잠긴다.

- `lib/path-containment.sh` 를 source 하고, 두 루프에서 `path=` 가 `PROJECT_DIR` 밖이면 **skip + 1회성 비차단 경고**(표식 정리 안내).
- orphan 루프의 접두사 제거 실패 경로(725행 — 절대경로가 그대로 `git ls-files` 로 가서 무조건 fail-closed)도 같은 검사로 도달 불가하게 만든다.
- 표식 자동 삭제는 하지 않는다 (판정 제외만 — 파일 파괴는 이 수리 범위 밖).

### 2. 결함 2 — 무관 문서의 대기 표식이 전역 차단

같은 파일의 소스 판정(244~350)과 표식 판정(537~807)이 편집 대상 `FILE_PATH` 를 전혀 연결하지 않는다 — 미리뷰 문서 1건이면 소스 전체 잠금 (실측 28회, 소스 주석 772~777이 이미 자인).

- **관련성 기준 (사용자 확정)**: 활성 작업 기준서(`select-active-dod` 경유)가 참조하는 문서의 pending 만 **차단**. 관련성 판정은 결정론적 — pending 표식의 `path=` (절대/상대 두 표기)가 활성 DoD 본문에 등장하거나, DoD 의 `plan ref:` 문서 본문에 등장하면 관련.
- 무관 문서의 pending 은 **비차단 경고**로 강등 (문서 경로·리뷰 명령 안내 포함 — 가시성 유지).
- 활성 DoD 부재 시: 소스 편집은 어차피 상류(활성 기준서 요구)에서 차단되므로 이 게이트의 전역 차단 분기는 도달 불가 — 방어적으로 "pending 전건 경고" 로 통일.
- 기존 `tests/` 하드코딩 면제(783~796)는 새 관련성 검사로 일반화되면 제거 검토 (동작 동등성 테스트로 확인).

### 3. 결함 3 — 커밋 게이트가 문자열 git 을 실제 커밋으로 오인

커밋 탐지 정규식이 `grep -qE` **행 단위** 평가라, (a) heredoc 으로 파일에 **기록될 텍스트**의 줄머리 `git commit` 이 실행으로 오인되고 (b) `cd <샌드박스> && git commit` 의 대상 저장소를 판별할 수단이 없다.

- (a) **무조건 수리**: 커밋 탐지 매처 쌍둥이(`git-subcommand-model.sh` 의 `git_clause_invokes`, `bash-guard-infra.sh` 의 `command_invokes`)가 heredoc 본문을 매칭 대상에서 제외 — `<<[-]?['\"]?WORD` 시작~종결자 줄 범위를 매칭 전에 소거(소거는 매칭 입력에만, 원문 불변). 인용/비인용 종결자, 다중 heredoc, 종결자 미출현(불완전 명령) 케이스를 fail-closed 로 (소거 불확실하면 소거하지 않고 기존 판정 유지).
- (b) **리터럴 경로만 면제 (사용자 확정)**: 같은 명령 내 선행 `cd` 절의 인자가 **리터럴 절대경로**(변수·치환·상대경로 불포함)이고 정규화 결과가 `PROJECT_DIR` 밖이면, 이후 절의 git 커밋을 게이트 면제. 변수(`cd "$SB"`)·명령 치환·상대경로·불명은 **기존대로 차단**. `cd` 이후 다시 저장소 안으로 `cd` 하는 절이 나오면 면제 해제.
- 탐지 SSOT 원칙 유지 — 로직은 lib 에 두고 소비자 3곳(classifier/dispatcher/커밋 게이트)이 공유. 두 매처의 판정 동등성을 테스트로 고정.

### 범위 외

- 표식 파일 자동 정리·마이그레이션 (판정 제외만 수행).
- 변수 해석·실행 추적 기반 대상 저장소 판별 (어휘 모델 유지 — 리터럴만 면제).
- pending 표식 freshness/content_sha 재설계 (기존 백로그 별건).
- 적대적 우회 하드닝 (위협 모델: 정직한 에이전트 규율 — 기존 확정 유지).

## 변경 파일

| 파일 | 변경 |
|---|---|
| `plugins/rein-core/hooks/pre-edit-dod-gate.sh` | 결함 1·2 — 경로 소속 검사 연결 + 관련성 기반 차단/경고 분리 |
| `plugins/rein-core/hooks/lib/git-subcommand-model.sh` | 결함 3 — heredoc 본문 소거 + 리터럴 cd 면제 판정 (SSOT) |
| `plugins/rein-core/hooks/lib/bash-guard-infra.sh` | 결함 3 — 쌍둥이 매처가 SSOT 소거 헬퍼 공유 |
| `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh` | 결함 3 — 커밋 감지 1회 계산 + 리터럴 밖 cd 면제 배선 (표식/커버리지/메시지 3게이트 공유) |
| `tests/hooks/test-pre-edit-dod-gate-repo-scope.sh` | 신규 — 결함 1·2 행위 기반 (cross-repo 표식·무관 문서 경고 강등·관련 문서 차단 유지) |
| `tests/hooks/test-git-mention-vs-invoke.sh` | 신규 — 결함 3 행위 기반 (heredoc 텍스트 통과·미종결 fail-closed·리터럴 cd 면제·변수 cd 차단·서브셸 닫힘 해제) |
| `tests/hooks/test-{spec-review-gate,pre-edit-dod-gate-sr-1-b,pre-edit-dod-gate-spec-tests-exempt,teach-forward-gates}.sh` | 갱신 — 활성 DoD 가 문서를 참조하도록 seeding 교체 (원래 검증 의도를 새 관련성 계약 위에서 유지) |
| `tests/hooks/test-pre-bash-test-commit-gate.sh` | 갱신 — `cd /other && git commit` 케이스를 GSD-3 재분류(면제)로 교체 + 변수 cd fail-closed 케이스 신설 (SX 구멍 보존) |

## 검증 기준

- [ ] 타 저장소 경로 표식이 있어도 이 저장소 편집이 차단되지 않고, 비차단 경고가 나온다.
- [ ] 활성 작업이 참조하는 문서의 pending 은 **여전히 차단**한다 (설계→코딩 순서 강제 보존 — FN 금지).
- [ ] 무관 문서의 pending 은 차단 없이 경고만 나온다 (임시 파일·scripts/ 편집 통과).
- [ ] heredoc 본문의 `git commit` 줄이 커밋으로 판정되지 않는다 (단일/다중/인용 종결자, 미종결 fail-closed).
- [ ] 리터럴 저장소 밖 `cd && git commit` 은 면제, 변수 `cd "$VAR"` 는 기존대로 차단된다.
- [ ] 실제 커밋(`git commit`, 저장소 안)은 종전과 동일하게 판정된다 — 기존 탐지 테스트 전량 무회귀.
- [ ] 두 매처(모델 lib / 가드 infra)의 판정이 동일하다 (동등성 테스트).
- [ ] 테스트는 행위 기반 — 실제 훅 실행 + 종료코드/JSON deny 단언 (source 후 내부 변수 검사 금지).
- [ ] `bash -n` 통과 + 훅 관련 기존 테스트 전량 무회귀.
- [ ] 코드 리뷰 + 보안 리뷰 통과.

## 라우팅 추천

- agent: 없음 — 메인 세션 직접 구현 (게이트 동작 변경 위험 경로, 변경 지점 좁게 유지)
- skills: `rein:codex-review`, `rein:security-reviewer`
- mcps: 없음
- rationale: 결함 1·2 는 같은 파일의 인접 경로라 순차, 결함 3 은 파일이 분리되나 매처 쌍둥이 정합을 한 손에서 유지하는 것이 안전. 직전 사이클과 동일하게 행위 기반 테스트로 새 계약을 먼저 고정한 뒤 진행

approved_by_user: true
