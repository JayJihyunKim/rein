# 2026-10-08~10 — 영향받는 테스트 자동 선택·testmon 자동 설치·리뷰 전 프로젝트 사전 검사 (사이클 2)

- DoD: `trail/dod/dod-2026-10-08-affected-tests-and-precheck.md`. 사용자 지시 "설계하고 개발까지 완료해" → "릴리즈까지 이어가". spec·plan 은 각 5회 리뷰 뒤 사용자 직접 승인, spec 정렬 편집은 이번 사이클 위임.
- 구현: 선택기 `rein-affected-tests.py`(프로젝트 스크립트 → jest/vitest/testmon → 내장 import 검색 → 전체 실행), pytest-testmon 자동 설치(정책 `auto_install_test_tools`), 래퍼 리뷰 전 사전 검사(`.rein/review-precheck.sh`, 검증 후 저장소 밖 임시 트리 추출·환경 정리 — 설계 D23), 정책 로더 조회 모드, SKILL·CHANGELOG Unreleased.
- 웨이브 1: 코드 리뷰 6회차 PASS(1~5회차 NEEDS-FIX — JS 연결 동적 import, 미검토 헬퍼·BASH_ENV 실행, 이스케이프 따옴표, 외부 심볼릭 링크, 임시 트리 잔존, `\xNN`/`\uNNNN`, 추출 전 검사, CRLF 줄 연속, SKILL 옛 서술. 6회차는 사용자 허용). 보안 standard PASS, Low 3(아래 후속). 커밋 `ce3a2ba`.
- 웨이브 2: 동기화 검사 갱신 + skills 러너 편입 — 코드 1회차 PASS, 보안 PASS. 커밋 `7e9d30e`. 웨이브 3: 코드 봉투 골든 재생성(생성 명령만, sub-item 8 만 변화) — 코드 1회차 PASS, 보안 PASS. 커밋 `2b3c0ad`.
- dev 병합 `4278aa5`. 병합 뒤 다섯 러너 실패 집합 = 사이클 전 기준선(eab97a1)과 같음. 차이는 hooks 임시 디렉터리 이름, hooks 세션 시작 주입량 실패 1건 소멸(index 축소 효과), rules 의 실패 0 요약 줄 1개(기준선 이후 추가된 테스트)뿐. drift 0.
- 판단 기록: 훅 실행 표식 `trail/dod/.session-has-src-edit` 가 웨이브 델타에 나타났으나 훅 런타임 표식으로 보고 구현 커밋에서 제외. 웨이브 1 trail 체크포인트에 spec D23 정렬 편집(표식 갱신 포함)을 함께 커밋 — plan 의 trail 전용 필터 밖이라 리터럴 목록으로 처리.
- 사고: hooks 러너가 stdin 대기로 3.5시간 정지(`test-bootstrap-check-helper.sh`) → 이후 러너는 전부 `< /dev/null` + `timeout 1800`.
- 후속: 보안 Low 3 — 선택기 pip 설치에 `-I` 누락(작업 트리 `pip.py` 섀도잉), 선택기 스크립트 환경에서 SHELLOPTS/BASHOPTS 미제거(래퍼와 불일치), 텍스트 출력 제어 문자 미필터. 기존 Low: sub-item 8 commit id 40-hex 제한. 래퍼가 codex 에 `--sandbox` 를 넘기지 않아 사용자 설정(danger-full-access)을 상속 — 별도 사이클. persona 요약 640B(>600), Windows advisory 스텁.
- 오케스트레이션: 메인 세션 지휘, parallel-execute 웨이브 3개 — 웨이브 1 edit_only 워커 6(+리뷰 지적 수정 재dispatch), 웨이브 2 edit_only 1(sonnet), 웨이브 3 mutating 1(sonnet). 보안 검토 워커 3(부모 발급). 리뷰·커밋·병합은 부모.
