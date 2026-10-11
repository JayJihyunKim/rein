# 2026-10-10 — 선택기 테스트 bash 3.2(macOS) 호환 수정

- DoD: `trail/dod/dod-2026-10-10-affected-tests-bash32.md`. v2.4.0 발행 워크플로 macOS 사전 테스트 실패의 후속.
- 원인: AT21b(c) 가 `mk_script "$(printf … '{…,…}')"` 로 만든 스크립트를 bash 3.2 가 중괄호 확장해 JSON 이 깨짐(선택기는 설계대로 "출력 형식 오류" 하강 — 제품 결함 아님). AT17(e) 는 macOS `wc -l` 앞 공백.
- 수정: AT21b(c) 본문을 따옴표 heredoc 변수로, AT17(e) 에 기존 `no_ws`. 로컬 bash 5.1·컨테이너 bash 3.2.57 둘 다 `PASS: 447  FAIL: 0`. 코드 리뷰 1회차 PASS, 보안 PASS. 커밋 fix 브랜치 → dev 병합. tests 전용이라 no bump, main 은 다음 릴리스 때.
- 오케스트레이션: 메인 세션 지휘, 수정 워커 1개(sonnet), 보안 검토 워커 1개(부모 발급).
