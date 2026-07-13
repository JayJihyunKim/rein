# DoD — trail/index.md 줄 수 한도(5~25)를 작성 시점에 강제

- date: 2026-07-13
- source: 사용자 직접 요청 (2026-07-13 세션 — "작성 후 검증해서 25줄 맞추는 왕복 대신 애초에 작성할 때 맞추게")

## 범위

trail/index.md 에 대한 Write/Edit/MultiEdit 시점에 **결과물 줄 수**를 계산해 한도(5~25줄) 위반이면 편집 자체를 거부하고 압축 안내를 낸다. 현행은 세션 종료 게이트의 사후 검사뿐이라 "초과 작성 → 종료 시 적발 → 다시 줄이기" 왕복이 발생 (오늘 세션 실증). 사전검사 철학(비용 지불 전 거부)의 소형 적용.

- 신규 sub-hook: 결과 줄 수 시뮬레이션 (Write=content, Edit/MultiEdit=현재 파일에 치환 적용) 후 위반 시 차단 + "몇 줄인지 / 한도 / 압축 우선순위" stderr 안내.
- 대상 경로: 프로젝트 루트 `trail/index.md` 만. 다른 파일 무간섭.
- 세션 종료 게이트의 기존 검사는 이중 방어로 유지 (제거 안 함).
- 도구/파싱 오류 시 fail-open (종료 게이트가 backstop) — 정책 위반 시에만 차단.

## 변경 파일

- plugins/rein-core/hooks/pre-edit-index-lines.sh (신규)
- plugins/rein-core/hooks/hooks.json
- tests/hooks/test-pre-edit-index-lines.sh (신규)

## 검증 기준

- [ ] 26줄 결과의 Write 가 차단되고 줄 수+한도 안내가 stderr 로 나온다
- [ ] 25줄/5줄 경계값 Write 는 통과, 4줄은 차단
- [ ] 파일을 26줄로 늘리는 Edit 차단, 26→24 로 줄이는 Edit 통과 (초과 상태 탈출 허용)
- [ ] trail/index.md 외 파일은 어떤 경우에도 무간섭
- [ ] stdin JSON 파싱 실패/python 부재 시 fail-open (exit 0)
- [ ] `bash -n` 구문 검증 + 전체 훅 테스트 스위트 회귀 GREEN

## 라우팅 추천

- 작업 유형: 신규 소형 게이트 (단일 훅 + 등록 + 테스트)
- 1순위: 주 세션 직접 구현 + `/codex-review` + 보안 리뷰 (훅 = 보안 민감 표면)
- meta_check: auto

approved_by_user: true  # 사용자가 2026-07-13 세션에서 기능을 직접 지정 요청

## 비고

- 버전 영향: 신규 게이트 훅 = user-facing. 증거 manifest 작업과 같은 minor 릴리스에 편승 예정.
- 이중 방어 근거: 편집 시점 게이트는 mtime/우회 편집(Bash 로 파일 조작)을 못 보므로 종료 게이트 유지가 필수.
- 수용 한계 (codex R3/R4 합의): 문자열 fast-path 는 index.md 를 가리키는 symlink 별칭 경로 편집을 놓친다 — 위협 모델(정직한 에이전트 규율, 적대적 우회 하드닝 보류)·hot-path 성능(전 편집 python 기동 회피) 근거로 수용. 별칭 경로는 즉시 차단 대신 종료 게이트가 실파일 재검사로 적발.
