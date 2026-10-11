# 2026-10-11 — 리뷰 래퍼 codex 샌드박스 read-only 고정

- DoD: `trail/dod/dod-2026-10-11-codex-review-sandbox.md`. 사용자 지시 "다음 거 이어서 해 자동모드 켜고 … 릴리즈 안한것들 모아서 한번에 릴리즈해".
- 변경(`fix/codex-review-sandbox` `1614b61`): 래퍼가 `codex exec` 에 `--sandbox read-only` 를 항상 전달(코드·문서 리뷰 공통, 루트 사본 동일). 이전엔 사용자 config 의 sandbox_mode(이 머신 danger-full-access)를 상속. 테스트 group 10(두 모드 read-only·workspace-write 부재·마커 무시), SKILL §1 표·Quick Reference·마커 절·§6.4·§6.6 정정.
- 경과: 처음엔 workspace-write 로 시작(read-only 는 mktemp 부터 실패해 리뷰어 테스트 재실행 불가 — 실측). 코드 리뷰 1회차 하위 설정(network_access·writable_roots) 미고정·문서 리뷰 쓰기 → 고침, 2회차 호출자 TMPDIR 이 쓰기 허용에 들어감(실측으로 홈 쓰기 재현) → 고침, 3회차 PASS. 그러나 보안 리뷰 Medium: 리뷰어가 저장소 안 게이트 제어 파일을 쓸 수 있고 지문 밖이라 미감지, codex 기본(read-only) 사용자에겐 권한 확대 → read-only 로 전환. `-C <빈 임시 폴더>` 대안은 AGENTS.md 미로드로 기각. 재리뷰 코드 PASS(리뷰어가 테스트 재실행 불가를 스스로 보고 — 적용 확인)·보안 PASS(기록 발급).
- 대가·후속: 리뷰어는 임시 파일 쓰는 테스트를 재실행하지 못함 — 증거 블록이 1차 증거. 재실행이 다시 필요하면 workspace-write + 게이트 제어 파일 변경 감지(리뷰 전후 비교) 설계가 선행 조건.
- 기존 실패(무관): `test-codex-effort-deterministic.sh`(자가검증 관문 도입 뒤 요청서 미갱신, CI 목록 밖), `test-review-evidence-manifest.sh` 4건(CI 정상, 로컬 grep→ugrep 차이 추정) — 변경 전 트리와 동일 실패 집합 확인.
- 교훈: codex 리뷰어 PATH 가 호출 셸과 달라 다른 codex 바이너리(0.92.0)를 볼 수 있다 — 버전 주장은 `which -a codex` 블록으로. 보안 리뷰는 스테이징 후에 받아야 통과 기록이 대상 파일에 묶인다. 샌드박스 축소는 "어느 사용자에게도 넓어지지 않는가" 로 판정.
- 등급: patch(종료 코드·차단 범위 불변). 이번 묶음 릴리스 v2.4.1 에 포함.
- 오케스트레이션: 강등(부모 직접) — 인자 한 줄 + 테스트·문서.
