# 완료 — 배포본에 task-axis 축 정책 동봉 + 위임 2단 해소 (v2 업데이트 전체 편집 차단 hotfix)

- date: 2026-08-28 완료
- DoD: `trail/dod/dod-2026-08-28-task-axis-bundled-policy.md`
- commit: `dc1b421` (dev, 미push)

## 문제

v2.0.0 으로 업데이트한 사용자 프로젝트에서 **모든 Edit/Write/MultiEdit 이 복구 불가로 하드 차단**. `active_task` 축이 배포 기본으로 v2 전환돼 있는데, 그 축이 요구하는 도구별 정책(task-axis 3파일)이 **이 저장소의 dogfood 오버라이드로만 존재**하고 배포본엔 동봉되지 않았다. 오버라이드 없는 프로젝트는 위임이 매번 실패 → fail-closed 로 편집이 전면 차단됐다. 우회책은 1.6.6 롤백뿐이었다.

## 수리

사용자 결정: "예전처럼 '작업 기록 필요' 복원" (거버넌스 기본 켬 유지).

1. 배포본에 축 정책 동봉 — `plugins/rein-core/policies/task-axis/{_version,edit-task,write-task,multiedit-task}.yaml` (trigger tool.pre / when.tool Edit·Write·MultiEdit / require active_task / failure_mode closed).
2. 위임 정책 위치를 2단 해소 — 프로젝트 오버라이드 우선, 없으면 배포 번들 폴백. 두 위치 모두에 파일이 없을 때만 fail-closed. 위변조 가드는 강화됨(오버라이드를 지워도 배포 기본값이 이어받아 축이 계속 발동).
3. FAIL 안내문 정정 — 실제 복구 명령 `claude plugin update rein` 로 안내 + 수동 정책 작성 금지 명시.

결과: 활성 작업 있으면 편집 허용, 없으면 복구 가능한 정상 안내(예전 흐름). 복구 불가 차단 제거.

## 변경 파일

- `plugins/rein-core/policies/task-axis/` 4파일 (신규 배포 번들)
- `plugins/rein-core/hooks/lib/active-task-gate.sh` (2단 해소 + 주석)
- `plugins/rein-core/hooks/pre-edit-task-gate.sh` (FAIL 메시지 정정)
- `tests/hooks/test-pre-edit-task-gate.sh` (재현 red→green + 양쪽 부재 fail-closed)
- `plugins/rein-core/tests/contract/test_bundled_task_axis_policy.py` (신규 — 배포 존재·로드·의미·드리프트 가드)

## 검증

- 재현 테스트 red→green (수정 전 exit 2 → 후 v2 정상 판정), task-gate 스위트 23/23
- 전체 훅 배터리 ALL SUITES PASSED
- 플러그인 pytest 1650 통과 (신규 계약 테스트 포함)
- 실제 배포 정책 e2e: 오버라이드 없음+작업 없음 → 복구 가능 DENY / 활성 작업 있음 → ALLOW
- 코드 리뷰: codex NEEDS-FIX 2건(메시지 정확성 Medium + 주석 Low) → 수정 → sonnet 셀프리뷰 PASS + 기록
- 보안 리뷰: PASS (우회·주입 표면 없음, 오히려 tamper guard 강화)

## 후속 (백로그)

- 종국 형태: `policies/default/` 로 tool.pre 요구 통합 후 task-axis 격리 폴더 제거 (`_version.yaml` 헤더의 이관 마지막 단계 — 별도 결정).
- dev 오버라이드 `.rein/policy/task-axis/` 유지 중 (dogfood 안정성) — 통합 시 함께 정리.
- 이 훅의 다른 6개 안내문(python 실패·라이브러리 누락 등)이 여전히 `rein update` 표현 사용 — 일반 설치 손상 안내라 이번 범위 밖이나, 표현 부채로 남김.

## 다음

main 사용자 배포 대기 — 배포 등급(hotfix patch 후보)·시점 사용자 승인 필요. push 도 미실행.
