# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **최근 작업 (2026-10-11)**: **v2.4.1 릴리스 완료(patch)** — 리뷰어 codex 샌드박스 read-only 고정(사용자 config 상속 차단) + 선택기 보안 Low 3. dev `df4807c`/main `d5dfd97`/public `e42126f`/Release Latest, 발행 워크플로 macOS 포함 성공. 상세 `trail/inbox/2026-10-11-release-v2-4-1.md`·`2026-10-11-codex-review-sandbox.md`.
- **이전 작업 (2026-10-10)**: v2.4.0 릴리스(minor) — 영향받는 테스트 자동 선택·testmon 자동 설치·리뷰 전 사전 검사. 상세 `trail/inbox/2026-10-10-release-v2-4-0.md`.
- **다음 세션 시작점 (2026-10-12)**: 후보 — **WSL 환경 경고**(세션 시작 시 프로젝트가 `/mnt/c` 아래거나 훅 스크립트가 윈도우식 줄바꿈이면 경고), sub-item 8 commit id 40-hex, `rein job` 중복 거부·진행률, 로컬 실패 2 스위트(effort-deterministic 요청서 미갱신·CI 밖 / evidence-manifest 로컬 grep 차이), 리뷰어 테스트 재실행이 다시 필요하면 workspace-write + 게이트 제어 파일 변경 감지 설계. 기존 실패: persona 요약 640B. Windows CI 잡은 10-12 제거.
- 이전 후속 후보(2026-09-22 사이클들)는 `trail/inbox/2026-09-22-*.md` 와 `trail/daily/` 참조 — EFFORT 마커 첫 줄 단독 인정, 후속 회차 전용 봉투, 지문 수집 범위, codex-ask `--full-auto` 예시 정정 등.
- **직전 릴리스: v2.4.1 (2026-10-11, patch)** main `d5dfd97`/public `e42126f`. **이전: v2.4.0 (2026-10-10)** main `896ce58`/public `8f62194`, v2.3.0 (10-08) — 상세는 각 inbox.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
- 코드 리뷰 요청서: 블록 밖에 "테스트+통과/PASS"·"N개 추가"·"실패/결함" 서술 금지(사전검사 exit 4). 본문에 `[EFFORT:…]` 문자열을 서술로 적지 말 것(래퍼가 본문 어디의 마커든 인식 — 첫 줄에만). 설계 문서 개정 시 표식이 풀려 소스 편집 즉시 차단 — 재검토·표식 후 편집. 리뷰 중에는 트리에 아무것도 쓰지 말 것(미추적 파일도 지문에 들어감 — 병렬 QA 도구 포함).
