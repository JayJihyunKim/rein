# 리뷰 증거 기계화 구현 — 완료 기록 (2026-07-13)

## 요약

실측 보고서(rein-improve-0713.md) 1순위 제언 구현 완료. codex 리뷰 래퍼가 code-review 요청서의 정량/PASS 주장에 `[EVIDENCE]`(claim/command/exit_code/output) 블록을 요구 — 없으면 codex 호출 전 exit 4 로 결정론적 거부, 유효 블록은 envelope 구조화 슬롯 + Claim Audit 교차확인 지시문으로 codex 에 전달. 정량 주장 없는 기존 요청서는 완전 무변경(기준 래퍼와 envelope byte 동일을 테스트로 고정).

## 검증 (철저 검증 지시 반영)

- 신규 행위 스위트 `tests/skills/test-review-evidence-manifest.sh` 142 단정 GREEN (수용 기준 14건 + 인프라 실패 2경로 + 통합리뷰 파생 회귀 fixture 19종).
- 기존 회귀 4종(래퍼 54/effort 29/failsoft 15/model-routing 90) + 미러 sha256 동일 + 3계열 run-all 전부 GREEN. 워커 보고 수치는 부모가 전부 재실행으로 재검증.
- 통합 codex 리뷰 8라운드 — 실결함 8건 적발·수정: Q3 후행 단어 경계(testing passed 오탐), envelope byte 비교 oracle 강화, EXIT trap 덮어쓰기, 다중 백틱 스팬, 정확 길이 closer(긴 런 접두 오인), 발췌 UTF-8 경계(스캐너+파서 2곳, 공용 함수화), 여러 줄 인라인 스팬(문서 전역 2단계 스캐너 재작성), escaped 백틱 우회, fence opener CommonMark 제한(EOF 마스킹 우회 봉쇄).
- 보안 리뷰 PASS — awk 코드/데이터 분리, 판별 계약 위조 불가(라인 단위 + anchored), 임시파일 0600+전 경로 정리, 도장 격리, spec 모드 skip 악용 이득 0 확인.

## 도그푸딩 (첫 실전 사용)

- 리뷰 요청서 자체가 새 문법의 첫 사용자 — 수치 주장마다 증거 블록을 달아 사전검사 통과.
- 7라운드 누적 요청서가 블록 상한(16) 초과로 exit 4 거부됨 → 안내대로 압축 재호출 — 상한 게이트의 실전 UX 검증 사례.

## 비차단 후속

- [Low, 보안 리뷰 권고] stderr 발췌의 C0 제어문자(ESC 등) 통과 — 기계 판별 계약은 무영향(표시 계층만). `san()` 에 제어문자 제거 1줄 추가를 다음 사이클에.
- 대형 diff 리뷰가 5분 시간 상한을 넘는 사례 2회 — 리뷰 시간 상한/분할 규약은 백로그 후보.
- 테스트 파일 머리말 주석 드리프트(이전 사이클 항목)와 함께 다음 정비 사이클에 편승.

## 릴리스

user-facing minor. trail 위생(patch)·index 줄수 게이트(minor)와 같은 릴리스로 묶음 예정 — bump 은 main 머지 시점 확정.
