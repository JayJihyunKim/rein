# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **직전 릴리스: v1.6.4 (2026-07-27)** dev `a003dee`/main `18ba9e6`/tag `v1.6.4` push+publish+mirror success (public plugin.json 1.6.4, 내부기록 404, public tag clean `fc6ded0`, Release Latest). 번들: 페르소나 만들기 입구·선택지 상한 2단 제시·전환 즉시 본문 반영·로더 호출 규약·인사말 후보 선택 + 리뷰 워치독 오판 수리(생존신호 3축·edge/level 유한 lease·임계 6창·기준선 0). 기계판정 minor→**사용자 결정 patch**. 리뷰: 설계 4R PASS/계획 4R/코드 6R+보안 PASS, 역변이 검증 2종. 상세: `trail/inbox/2026-07-27-release-v164.md`.
- **완료 (2026-08-05, dev 2건 커밋 — 배포·버전등급은 미결정)**: ①리뷰 회차 예산 사이클(`76e4c67`+trail `8177869`) — 문서 리뷰 전용 판정 계약 + 회차 예산(상한 5) + 카운터 경로 하드닝. 코드 1차 5R+2차 5R PASS, 보안 재검토 2회 PASS. 상세: `trail/inbox/2026-08-04-review-scope-and-round-budget.md`(회전 후 daily/weekly). ②게이트 판정 범위 결함 3건(`2ad12a5`) — 표식 저장소 경계 물리 판정·무관 문서 경고 강등·heredoc/샌드박스 커밋 구분(워크트리 판별 포함). codex 2R + sonnet 대체 2R(codex 한도 8/10 까지) PASS + 보안 지적 1건 수리 후 PASS, 역변이 검증 4종. 상세: `trail/inbox/2026-08-05-gate-scope-defects.md`.
- **다음 작업 (사용자 확정 순서, 2026-08-05 갱신)**: ①설계→계획→테스트 연쇄 드리프트 구조 재설계 ②rein 산출물 경로 재배치(주요 버전급). 백로그 소: hooks 등록 검사 테스트 기존 실패·성능 테스트 경계선(둘 다 2026-08-05 관찰). 상세: `trail/weekly/2026-W31.md` (backlog-next-two-cycles 절).
- **이전 릴리스: v1.6.3 (2026-07-23)** dev `54bb1bb`/main `9db782c`/tag `v1.6.3` push+publish+mirror success (public plugin.json 1.6.3 도착, 내부기록 404 strip, public tag clean `4fbda74`). 번들: 페르소나 사용자 선택+커스텀·변경 인사말·대화 언어 적응(영어권)·전환 메타금지 + codex 리뷰 시간상한 워치독. 기계판정 minor→**사용자 결정 patch**. 릴리스 번들 리뷰 sonnet 대체 PASS(codex 워치독 timeout)+보안(문서/버전-only). 후속 Low: 닫는 fence·greeting L4필터·Scope ID·`tests/agents` routing-map 875B. 상세: `trail/inbox/2026-07-23-release-v163.md`.
- **이전 릴리스 (상세는 각 작업 기록)**: v1.6.2(2026-07-22, 리뷰 사이클 효율화 — 자가검증 관문+출력축소, main `a7062b0`) / v1.6.1(2026-07-13, 리뷰 증거 블록 필수+index 줄수 게이트+trail 위생, main `c5f5c88`) / v1.6.0(2026-07-10, codex 모델 프로필 라우팅, main `b815f85`). 각 후속 Low 는 해당 inbox 참조.
- **이전 완료**: v1.5.8 릴리스(2026-06-26, effort 결정론적 산출, patch — 후속 Info 2건+content_sha 미적용) / GitHub Releases 백필 31개+DoD 21건 아카이브(2026-07-03, `trail/inbox/2026-07-03-github-releases-backfill.md`).
- **이전 릴리스**: v1.5.7(`059ed70` helper 호출 `${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/` 정정, 06-18), v1.5.6(`0777835` 문서·운영기록·버전문자열-only 커밋 보안 재검토 자동 면제 — 단일-clause 전경 `git commit` 만, 06-17), v1.5.5(`fd61010` 마커 감사 백로그 M1~M4 봉합, 06-16), v1.5.4(`f6f6b6c` 자동모드 안내 정정, 06-15), v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소, 06-11), v1.5.1(`e470def` 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋, 06-09), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
