# 2026-09-04 — `.rein/state.json` 무시 규칙 + 리뷰 지문 억제 수리 완료

대상 DoD `trail/dod/dod-2026-09-04-rein-state-gitignore-digest.md` (이슈 리포트 `docs/reports/[issues]_2026-09-04.md`). 코드 커밋 dev `ab55438`.

## 무엇이 바뀌었나
- 초기화가 만드는 무시 목록에 `/.rein/state.json`, `/.rein/state-pending-*.log`, `/.rein/.onboarded` 추가. 이미 초기화된 프로젝트는 세션 시작 때 `--ensure-gitignore` 서브모드가 누락 패턴만 보강(다른 파일 생성 없음, best-effort).
- `.gitignore` 쓰기는 단일 fd(`O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW|O_NONBLOCK`) + fstat 정규 파일 검사(심볼릭 링크·FIFO·디렉터리 거부 exit 2) + `flock(LOCK_EX)` 아래 읽기·계산·append. git 조회 10초 timeout, 서브모드 SIGALRM 15초 상한(반환 시 해제).
- 리뷰 지문: 스테이징된 삭제(정확히 `D `, `??` 재등장 제외)의 디스크 내용을 WORKTREE 지문에서 억제. 보조 조회 실패는 지문 부재로 전파(빈 집합 금지). STAGED 범위 불변. 대상 경로 목록은 그대로(내용만 부재).

## 검증
- codex 6회차(예산 5 + `[MAX_ROUNDS:6]` 1회 연장, 상세 `trail/inbox/2026-09-04-state-gitignore-review-rounds.md`) → 6회차 지적 2건 3줄 이내 수정 → 규정 §3 자체 리뷰 경로로 독립 sonnet 리뷰어 PASS(읽기 전용·스위트 재실행·엣지 탐침·이슈 e2e 재현). 코드 리뷰 기록 → 스테이징 → 보안 리뷰(standard) PASS 기록 → 커밋(같은 지문).
- 스위트: gitignore 60, 세션 시작 24/24, digest 단위 48, plugin pytest 1669, 배터리 3종 ALL SUITES PASSED.

## 후속(Low, 기록만)
- `.gitignore` 에 UTF-8 이 아닌 바이트가 있으면 `_read_all` 이 traceback(exit 1)으로 죽음 — 수리 전부터 있던 동작, 훅은 출력을 버려 사용자 영향 없음. 손으로 실행할 때만 보임. 정리 시 `UnicodeDecodeError` → 거부 메시지.
- SIGALRM 이 `os.write` 도중 울리면 부분 쓰기 가능(15초 근접 경합에서만, 미재현).
- `_git_changeset_facts()` 기준 WORKTREE digest 3회 × 억제 조회 = `git status` 호출이 이전 대비 2~3배(증거 발급 경로라 hot-path 아님). 줄이려면 `(경로, 삭제집합)` 스냅샷을 필터 단계까지 전달하는 API 변경 필요 — DoD 계약으로 이번엔 제외.
- 독립 리뷰어가 탐침 중 저장소 루트 `.gitignore` 를 실수로 덮었다가 즉시 복원(`git diff` 비어있음 확인). 리뷰어 지시문에 "저장소 루트 상대경로 쓰기 금지" 한 줄 추가할 것.
