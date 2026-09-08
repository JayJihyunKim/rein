# DoD — v2.1.0 이후 잔여 Low 후속 일괄 수리 (버그 수정)

- date: 2026-09-08 착수
- plan ref: 없음 (v2.1.0 사이클 ③ Low 3건 + v2.0.3 후속 Low 4건 — 각 리뷰 회차의 비차단 지적)
- approved_by_user: true (2026-09-08 "푸시하고 나머지 작업 다 진행해버리자")

## 배경

v2.1.0 구현·릴리스 리뷰(사이클 ③)와 v2.0.3 통합 리뷰가 남긴 Low 지적이 index 에 잔여 후보로 누적돼 있다. 모두 동작 결함이거나 테스트 신뢰도 결함이며 서로 파일이 겹치지 않아 한 웨이브로 묶는다. 진단 기능·설계 변경은 포함하지 않는다.

## 범위

1. 리뷰 래퍼 `_readiness_check` advisory 분기가 혼합 목록(`QUANT_FLAGS`)을 읽는 것을 advisory 전용 목록·건수로 정정 (동작 동일 — 변수 의미 정합). 루트 미러 byte 동일 유지.
2. 자가검증 관문 테스트 SV29 픽스처를 역방향(문서-only 관측 + 비센티널 subject)으로 정확히 재현 — 현재는 코드 파일 staged 라 A1 로도 발동해 A7 역방향을 격리하지 못함.
3. 워커 `git stash` 구조적 차단: Bash 안전 가드에 [P12] 신설 — 훅 입력에 `agent_id` 가 있으면(서브에이전트 안) 변경성 `git stash`(인자 없음/push/pop/apply/drop/clear/save/branch/create/store/옵션 시작)를 JSON deny(`SUBAGENT_STASH_BLOCKED`). `git` 과 `stash` 사이의 전역 옵션(`-C`/`-c`/`--git-dir`/`--work-tree`/기타 `-…`)은 P10 의 접두 문법을 재사용해 같이 잡는다(codex 1회차 Medium). 변경성 서브커맨드에 git 2.51 의 `export`/`import` 포함(codex 4회차 Medium). `git stash list|show` 와 메인 세션은 비차단; `--help` 와 따옴표 안에 구분자가 든 언급은 보수 방향(차단)으로 수용하고 테스트 이름에 명시. 종결자 계약(codex 2회차 High): stash 토큰 뒤에 올 수 있는 것은 줄 끝·`; & | ) } # > <`·따옴표·fd 번호 리다이렉션·끝 역슬래시(다음 단어 미상 → 차단 쪽)로 한 번에 정의하고, 역슬래시 줄바꿈은 이 판정에서만 이어 붙여 본다. 별칭·eval·변수 결합은 정직한 에이전트 위협 모델 밖으로 명시. 다른 명령 hot path 비용 0(패턴 매치 뒤에만 `agent_id` 추출). parallel-execute 스킬 금지목록에 stash 한 구절 추가.
4. 초기화 스크립트 `.rein/project.json` 존재 판정 `is_file()` 로 좁힘(2곳). 마커 자리에 디렉터리가 있으면 traceback 대신 명시 거부.
5. 비 UTF-8 `.gitignore`: 디코드 traceback 대신 바이트 보존 처리(`surrogateescape`) — 기존 내용 byte 그대로 두고 패턴만 추가. 거부가 아닌 보존인 이유: 거부하면 정당한 Latin-1 `.gitignore` 프로젝트가 초기화 자체를 못 하는 잠금이 됨.
6. 루트 `scripts/rein.sh` 의 `: > "$log"` → `printf '' > "$log"`. 정적 검사 스위트 범위에 루트 `scripts/*.sh` 추가.
7. `test-job-gc.sh` 흔들림: (d) 에서 띄운 작업이 끝날 때까지(종료 파일 + 메타 `finished_at`) 기다린 뒤 정리. 같은 클래스(EXIT trap 의 `rm -rf` 가 래퍼 마지막 메타 기록·비동기 GC 와 경쟁 → "Directory not empty" 로 스위트 rc 오염)가 `test-job-completion-wrapper.sh` 에서도 재현돼(배터리 2회차 + 직접 재실행), 실제 작업을 띄우는 job 스위트 전부의 정리 trap 을 재시도형(상한 있음)으로 통일. `run-all.sh` 6종이 실패한 스위트 이름을 마지막에 출력.
8. 포함하지 않음: 스캐너 규칙 변경, plan/spec 편집, CHANGELOG(배포 사이클에서), 회차 카운터 파일 정리(운영 — 미추적 삭제).

## 변경 파일

- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- tests/skills/test-review-selfverify-gate.sh
- plugins/rein-core/hooks/pre-bash-safety-guard.sh
- plugins/rein-core/hooks/lib/bash-guard-infra.sh, plugins/rein-core/hooks/lib/git-subcommand-model.sh (절 시작 집합에 `{`·`)`(case 패턴 끝)·백틱·명령을 이끄는 POSIX 예약어 `if then elif else while until do !` 추가 — 쌍둥이 매처 동일 수정; codex 3·4회차 High 를 "토큰 형태만 보고 문법 위치는 보지 않는다(예약어 뒤 언급은 보수 방향 차단)" 계약으로 종결, 파서 전환은 범위 밖으로 명시)
- tests/hooks/test-pre-bash-safety-guard.sh
- plugins/rein-core/skills/parallel-execute/SKILL.md
- plugins/rein-core/scripts/rein-bootstrap-project.py
- tests/scripts/test-bootstrap-gitignore.sh
- scripts/rein.sh
- tests/hooks/test-no-special-builtin-redirect.sh
- tests/scripts/test-job-gc.sh
- tests/scripts/test-job-completion-wrapper.sh, test-job-detach-posix.sh, test-job-detach-mingw.sh, test-job-list.sh, test-job-status.sh, test-job-start-skeleton.sh, test-job-stop-posix.sh, test-job-stop-mingw.sh, test-job-transport.sh, test-job-tail.sh (정리 trap 재시도형 통일)
- tests/scripts/run-all.sh
- tests/scripts/test-run-all-failure-listing.sh (신규 — run-all 실패 목록 출력 행위 검증, codex 1회차 Low)
- tests/hooks/run-all.sh
- tests/skills/run-all.sh
- tests/agents/run-all.sh
- tests/integration/run-all.sh
- tests/rules/run-all.sh

## 검증 기준

- [x] (red→green) 안전 가드: `agent_id` 있음 + `git stash` / `git stash pop` → deny(`SUBAGENT_STASH_BLOCKED`); `agent_id` 있음 + `git stash list` → 통과; `agent_id` 없음 + `git stash` → 통과; `echo "git stash"` → 통과(절 앵커링). 기존 P1~P11·GMF·I 케이스 무회귀.
- [x] (red→green) 초기화 스크립트: `.rein/project.json` 이 디렉터리인 프로젝트에서 `--ensure-gitignore` 가 `.gitignore` 를 쓰지 않음; 비 UTF-8 `.gitignore`(Latin-1 바이트 포함) 에서 rc 0 + 원본 바이트 접두 보존 + 패턴 추가.
- [x] (red→green) SV29 가 `mk_docs_dirty` + 비센티널 subject 로 exit 4 — 같은 픽스처에서 센티널 subject(SV21)는 exit 0 이므로 subject 만이 차이.
- [x] 정적 검사 스위트가 루트 `scripts/*.sh` 도 스캔하고 통과.
- [x] `test-job-gc.sh` 가 작업 종료를 기다린 뒤 정리; job 스위트 전부의 정리 trap 이 재시도형이라 래퍼 지연 기록·비동기 GC 와 겹쳐도 rc 를 오염시키지 않음(각 스위트 연속 재실행으로 확인); run-all 6종이 실패 시 스위트 이름 목록을 출력(성공 시 출력 불변).
- [x] 래퍼 advisory 분기 변수 정정 후 tests/skills 스위트 통과, 루트 미러 `cmp` 동일.
- [x] codex 코드 리뷰 PASS + 보안 검토 기록 후 커밋.

## 라우팅 추천

agent: rein:feature-builder-fix
skills: [rein:codex-review]
mcps: []
security_tier: standard
complexity: medium
model_hint: sonnet
effort_hint: medium
rationale:
  - 7건 모두 파일이 겹치지 않음 → 같은 트리 edit_only 워커 3개 병렬 + 부모 검증·리뷰·커밋
  - 훅 차단 범위 신설(서브에이전트 한정) → 보안 검토 표준 등급
approved_by_user: true

## 완료

- 2026-09-08 dev `f74eca2`. codex 4회차(1회차 Medium+Low 3 / 2회차 High+Low 2 / 3회차 High+Low / 4회차 High+Medium) 뒤 사용자 승인 종결 + 부모 자체 검토 기록, 보안 검토 PASS(대상 없음), 배터리 여섯 묶음 통과. 상세 `trail/inbox/2026-09-08-post-v210-low-followups.md`.
