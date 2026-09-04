# 2026-09-04 — `.rein/state.json` 무시 규칙 + 리뷰 지문 억제 사이클: 리뷰 회차 기록

대상 DoD: `trail/dod/dod-2026-09-04-rein-state-gitignore-digest.md` (이슈 리포트 `docs/reports/[issues]_2026-09-04.md`)

## 회차별 지적과 조치

| 회차 | 판정 | 지적 | 조치 |
|---|---|---|---|
| 1 | NEEDS-FIX | Medium: 상태 파서가 `DU`/`DD`(충돌) 를 스테이징 삭제로 오인 · Low: "출력 정확히 한 줄" 미검증 | 정확히 `D ` 만 억제 + 파서/실제 `DU` 충돌 회귀 2건 · 한 줄+stderr 비어있음 단언 |
| 2 | NEEDS-FIX | Medium: 안내 한 줄에 경로를 echo → 개행 포함 경로면 2줄 | 안내문에서 경로 제거(고정 문구) + 개행 경로 케이스 (v) |
| 3 | NEEDS-FIX | Medium: `.gitignore` 가 FIFO 면 blocking open 으로 세션 시작 훅 무기한 정지 | `O_NONBLOCK` + fd `fstat` 정규 파일 검사 + git 조회 10초 timeout + 서브모드 SIGALRM 15초 상한 · FIFO 케이스 (vi) + 훅 픽스처 V |
| 4 | NEEDS-FIX | Medium: 보조 `git status` 실패가 빈 억제 집합 → 삭제 예정 내용 재해싱 · High(주장): 픽스처 수 "23→24" 근거 없음(실제 21→24) | 실패 시 None → digest 부재(unresolved) 전파 + 회귀 · 주장 정정 · CLI 주석("status 재실행 없음") 현행화 |
| 5 | NEEDS-FIX | Medium: read→append 동시 실행 시 같은 블록 중복 append | 단일 fd `O_RDWR\|O_APPEND` + `flock(LOCK_EX)` 아래 읽기·계산·append · 동시 2프로세스×12회 케이스 (vii) |
| 6 | NEEDS-FIX | Medium 2: `.gitignore` 가 디렉터리면 traceback(exit 1) · 서브모드 alarm 반환 시 미해제 | `EISDIR` → 동일 거부(exit 2) + 케이스 (viii) · `try/finally signal.alarm(0)` + 케이스 (ix) |

- 예산 5회차 소진 후 6회차는 요청서 첫 줄 `[MAX_ROUNDS:6]` 선언으로 1회 연장(래퍼 기록). 근거: 사용자의 이 세션 상시 지시("묻지 말고 끝까지 완주") + 5회차 수정이 3줄 초과라 자체 리뷰보다 독립 회차가 적합.
- 6회차 지적 2건은 각각 3줄 이내 수정 → 규정 §3 "Medium ≤3줄 = 자체 리뷰" 경로: 독립 sonnet 리뷰어(읽기 전용, 스위트 재실행 + 엣지 탐침)로 종결.
- 회차마다 다른 축의 실제 결함(파서 상태·개행 경로·FIFO·실패 의미·동시성·디렉터리/타이머)이 나왔다 — 같은 축 반복은 아니었으나, 파일 하나를 "읽고 붙이는" 함수에 6회차가 든 건 처음부터 "정규 파일·잠금·상한" 계약을 적지 않은 탓. [[feedback_review_round_edge_class_stop_at_three]] 자매 교훈.

## 최종 검증(자체)
- 문법: shell 3 + python 4 전부 통과. plugin pytest 1669 통과. 배터리 3종(hooks/scripts/integration) ALL SUITES PASSED. gitignore 스위트 60, 세션 시작 24/24, digest 단위 48.
