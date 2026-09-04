# DoD — 미초기화 프로젝트에서 세션 종료 훅이 trail 잔여물을 만들어 "부분 완료" 오진 (버그 수정)

- date: 2026-09-02 착수
- approved_by_user: true (2026-09-02 "둘 다 승인, 병렬 구현 시작 (권장)" 선택)
- plan ref: 없음 (버그 수정 — brainstorm `docs/brainstorms/2026-09-02-non-git-onboarding.md` (B) 항)
- 근거 리포트: `docs/reports/[issues]_2026-09-01.md` §4-B

## 배경

세션 종료 훅(`hooks/stop-session-gate.sh`)은 종료 마킹 함수를 `trap EXIT` 로 스크립트 상단에서 등록한다. 그 뒤의 비활성(degraded) 검사와 초기화 미완료 검사가 `exit 0` 으로 빠져나가도 trap 이 실행되어 집계 스크립트(`scripts/rein-aggregate-incidents.py` `set_session_end`)를 부르고, 그 함수는 `trail/incidents/` 를 무조건 만든다. 결과: 초기화한 적 없는 프로젝트에 `trail/incidents/` 잔여물이 생기고, 다음 프롬프트에서 `bootstrap-check.sh` 의 3마커 판정이 partial 로 바뀌어 "이전 bootstrap 이 중간에 실패했을 수 있습니다" 라는 오진이 나온다. `aggregate()` 도 같은 무조건 mkdir 를 가진다.

## 범위

초기화가 완료되지 않은 프로젝트(`.rein/project.json` 부재)에서는 어떤 훅도 `trail/` 아래에 파일을 만들지 않는다. 두 겹으로 막는다:
1. 집계 스크립트: `set_session_end()` 와 `aggregate()` 는 `project_dir/.rein/project.json` 이 없으면 폴더를 만들지 않고 즉시 0 으로 반환한다(다른 필드·동작 불변).
2. 세션 종료 훅: trap 등록은 스크립트 상단에 그대로 두고(가장 먼저 exit 하는 우회 탈출구까지 잡아야 하므로), 마킹 함수가 EXIT 시점에 초기화 여부(`.rein/project.json` 일반 파일 + `trail/`)를 직접 확인해 초기화된 프로젝트면 어느 종료 경로든(비활성 표식 유무·소스 편집 유무·우회 탈출구 포함) 마킹하고, 미초기화면 마킹하지 않는다 — 마킹 여부가 "어느 줄에서 exit 했는가" 가 아니라 프로젝트 상태로 결정된다. 우회 탈출구의 감사 로그도 초기화된 프로젝트에서만 파일로 남긴다.
3. 세션 종료 훅의 advisory 요약 호출(`advisory-summary`)에 `--project-dir` 이 빠져 있어 집계 스크립트가 현재 작업 디렉토리의 사건 기록을 읽는다(재현: 빈 폴더 대상 실행에서 다른 저장소의 "89회 반복" advisory 출력). 다른 세 호출과 같이 `--project-dir "$PROJECT_DIR"` 를 넘긴다.

포함하지 않음: `bootstrap-check.sh` 의 partial 판정 규칙 변경(잔여물의 원천을 막으므로 열거식 예외 불필요), 마커 개명, non-git 온보딩(별도 DoD).

## 변경 파일

- `plugins/rein-core/scripts/rein-aggregate-incidents.py` (`aggregate`, `set_session_end` 두 함수의 초기화 가드)
- `plugins/rein-core/hooks/stop-session-gate.sh` (마킹 함수가 EXIT 시점에 프로젝트 상태를 직접 확인 — 초기화된 프로젝트(`.rein/project.json` 일반 파일 + `trail/`)면 어느 종료 경로든 마킹(문서만 만진 세션·우회 탈출구·비활성 표식 유무 무관), 미초기화면 마킹·폴더 생성 없음. 우회 탈출구의 감사 로그도 초기화된 프로젝트에서만 파일로 남기고 미초기화면 stderr 만. advisory 호출 `--project-dir`)
- `scripts/rein-aggregate-incidents.py` (저장소 루트 메인테이너 폴백 사본 — 플러그인 원본과 바이트 동일 유지, `test-plugin-scripts-bundle.sh` 파리티)
- `tests/hooks/test-stop-gate.sh` 또는 `tests/hooks/test-stop-incident-gate.sh` (재현: 미초기화 샌드박스에서 Stop 훅 실행 후 `trail/` 부재; 정상 초기화 프로젝트에서는 마킹 여전히 기록)
- `tests/scripts/test-aggregate-combined-cli.sh` (미초기화 dir 에 `set-session-end true` / 집계 → `trail/` 미생성, rc 0)

## 검증 기준

- [ ] (red→green) 초기화 안 된 샌드박스에 Stop 훅 실행 → 수정 전엔 `trail/incidents/` 생성, 수정 후엔 `trail/` 부재. 이어서 `bootstrap-check.sh` 가 partial 이 아닌 fresh 안내를 냄.
- [ ] (red→green) 집계 스크립트 `set-session-end true` 를 미초기화 dir 에 실행 → `trail/` 미생성, rc 0. `aggregate` 경로도 동일.
- [ ] 초기화된 프로젝트: 정상 경로·"소스 편집 없음" 조기 종료·비활성 표식이 있는 세션 모두 session_end=true 마킹(다음 세션 시작의 비정상 종료 안내 오탐 없음 — 2세션 재현으로 확인). 미초기화 프로젝트만 마킹·폴더 생성 없음(우회 탈출구 포함). 초기화 표식 판정은 훅과 같은 "일반 파일" 기준.
- [ ] advisory 요약이 현재 작업 디렉토리가 아니라 PROJECT_DIR 의 사건 기록을 읽는다(cwd 를 다른 저장소로 둔 테스트).
- [ ] 훅 배터리·스크립트 배터리 초록.

## 라우팅 추천

agent: rein:feature-builder-fix
skills:
  - rein:codex-review
  - superpowers:test-driven-development
mcps: []
security_tier: light
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 버그 수정(마킹 함수의 초기화 가드 + 스크립트 가드 2곳 + advisory 인자) → feature-builder-fix, 재현 테스트 먼저
  - 파일 2개 + 테스트 2개, 기존 패턴 확장 → light/low. 보안 표면 없음
approved_by_user: true
