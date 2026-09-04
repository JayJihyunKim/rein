# 2026-09-04 — 세션 시작 훅: 리눅스 POSIX 모드 셸 종료 결함 + 초기화된 프로젝트 표식 삭제 실패 무음 수리 완료

대상 DoD `trail/dod/dod-2026-09-04-session-start-stuck-marker-rc0.md`. 코드 커밋 dev `6ece5d1`. 계기: (1) v2.0.3 main 통합 리뷰 4회차 High — rc=0 경로 표식 삭제 실패 무음, (2) dev push CI(우분투) 실패 — 세션 시작 스위트 픽스처 S.

## 원인과 수리
- **리눅스 CI 실패 원인(도커 `ubuntu:24.04`, bash 5.2, 비루트로 재현·확정)**: `hooks/lib/git-required-guidance.sh` 가 안내 표시 플래그를 `: 2>/dev/null > "$flag"` 로 만들었다. `:` 는 POSIX *특수* 내장명령이라 POSIX 모드(bash 5 + `POSIXLY_CORRECT=1`)에선 리다이렉트 실패가 **셸 종료**가 된다 — 읽기 전용 `.claude/cache` 에서 `bootstrap_check` 를 담은 명령 치환 서브셸이 exit 1 로 죽고, 훅은 rc=1 을 받아 초기화를 건너뛴 채 무음 종료. 맥 `/bin/bash` 3.2 는 이를 강제하지 않아 로컬은 초록. 픽스처 S 는 정확했고 훅이 결함. 수리 = `printf ''`(일반 내장명령) + 같은 형태 3곳(`select-active-dod.sh` 세션 플래그, `post-edit-dod-routing-check.sh` 표식, `rein-codex-review.sh` 임시파일 + 루트 미러) 교체, stderr 억제는 리다이렉트 **앞**에.
- **rc=0 표식 삭제 실패 무음**: 제거가 실패했고 게이트 판정(`rein_is_degraded`, `-f`)으로 여전히 보이면 초기화 경로(exit 4)와 같은 한 줄 안내(공용 함수 `rein_emit_stuck_marker_line`, 문구 바이트 동일). 안내를 낸 실행은 1회성 프라이머 백필을 건너뛰어 stdout 정확히 한 줄(다음 세션에 프라이머 출력). 디렉터리가 표식 이름을 차지하면 무음(게이트도 비활성화 안 됨).
- **재발 방지**: 안내 lib 케이스 N(읽기 전용 캐시 + POSIXLY_CORRECT=1 자식 bash 에서 호출자 생존·rc 0·stderr 무누출), 정적 검사 `tests/hooks/test-no-special-builtin-redirect.sh`(`: > file` 명령 위치 휴리스틱 — 따옴표 구간 제거 후 매칭, 양성 15·음성 18 자기검사, ugrep/GNU/BSD grep 호환; 한계를 헤더에 명시, 권위 회귀는 케이스 N).

## 리뷰
- codex 4회차: 1회차 Medium 2(정규식 범위 과대·`-e` vs `-f`) + 주장 High/Medium(항목 수·문구 변경), 2회차 Medium 2(정규식 누락 형태·리다이렉트 순서 2곳) + 주장 High 2(파일 수), 3회차 Medium 3(정규식 엣지·안내+프라이머 6줄·DoD 파일 목록) → 4회차 PASS. 정적 검사 정규식은 3회차 연속 같은 축이라 "휴리스틱 + 한계 명시 + 권위 회귀는 런타임 케이스" 로 계약을 닫음. [[feedback_review_round_edge_class_stop_at_three]]
- 보안(standard) PASS, 코드·보안 기록 같은 지문 결속 후 커밋.

## 교훈
- **테스트 하네스 편차 2종**: (1) preflight 러너가 `CLAUDE_PLUGIN_ROOT` 를 전역 export 하면 9개 스위트가 다른 경로를 탐(CI 는 미설정) — 실패를 "main 트리 결함"으로 단정하기 전에 같은 env 로 dev 에 재현. (2) 맥 셸의 `grep` 이 ugrep 이라 빈 대안 `(a|)` 을 거부 — 테스트 정규식은 옵션 그룹 형태로.
- 도커 재현 이미지 `rein-linux-repro`(ubuntu:24.04 + git/python3/PyYAML/jq, 비루트) — 스크래치패드 Dockerfile. 저장소는 읽기 전용 마운트. 정리: `docker rmi rein-linux-repro`.
- 워커/리뷰어의 `rm -rf` 는 권한창에서 영구 정지(보안 리뷰어 1회 10분 정지 → 정지·재배치). 리뷰어 지시문에 삭제·권한 변경 금지 + mktemp 방치 규칙.

## 후속(기록만)
- 보안 리뷰 참고: `scripts/rein.sh:368` 의 `: > "$log"` 도 같은 형태(단 `set -e` 아래라 실패 시 어차피 중단 — 동작 차이 없음). 정적 검사 범위(플러그인 hooks/scripts/bin) 밖이라 루트 `scripts/` 까지 넓히는 건 다음 사이클.
- 표식 삭제 실패 후 `-f` 검사와 출력 사이 다른 세션이 표식을 지우는 경합은 무해한 안내 1줄(잠금 범위 밖).
