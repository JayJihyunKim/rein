# 2026-10-10 — 선택기 보안 Low 3건 보강

- DoD: `trail/dod/dod-2026-10-10-selector-security-low.md`. 사용자 지시 "작업 이어서 해" — index 다음 시작점 첫 항목.
- 변경(`fix/selector-security-low` `0f5a6b3`): venv pip 설치 `-I`(실측: -I 없이는 cwd `pip.py` 실행됨), 스크립트 환경 SHELLOPTS·BASHOPTS 제거, 텍스트 출력 줄별 C0/C1 → `?`. 테스트 AT21b(b2)·AT40b 추가, AT30 기대 argv 갱신(가짜 venv 는 `-I -c` 만 탐지로). SKILL 안내문 pip 표기 동기화.
- 검증: 선택기 테스트 bash 5.1·bash 3.2 컨테이너 둘 다 실패 0, 수정 전 새 단언 5건 실패 확인. drift 정상.
- 리뷰: 코드 리뷰 1회차 PASS(Low 2 참고), 보안 standard PASS(기록 대상 없음 — 정상 건너뜀, Low 1 참고).
- 후속(Low): AT40b 에 TAB·ESC·C1 대표값 단언 없음 / 설계 문서 pip 예시 옛 표기(설계 문서 개정은 표식 해제 유발 — 다음 설계 개정 때) / 선택기 오류 메시지(경로·예외) 제어 문자 미치환(사람용이라 위험 낮음) / JSON 출력은 C1 을 이스케이프하지 않음(구조 주입 없음).
- 교훈: bash 3.2 는 `$(cat <<'EOS' … EOS)` 안의 `case … in x)` 괄호를 잘못 파싱 — 테스트 본문에서는 `[[ ]]` 조건을 쓴다. 환경 변수로 켜지지 않는 셸 옵션(extdebug)은 비반영 테스트로 쓸 수 없다 — nullglob 사용.
- 등급: patch 후보(사용자 동작 보강, 종료 코드·차단 범위 불변). 릴리스·main 반영은 안 함 — 다음 릴리스 때.
- 오케스트레이션: 강등(부모 직접) — 세 줄 수정이라 워커 위임 비용이 더 큼.
