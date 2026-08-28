# DoD — 배포본에 task-axis 축 정책 동봉 + 위임 폴백 (v2 업데이트 후 전체 편집 하드 차단 hotfix)

- date: 2026-08-28 착수
- plan ref: 없음 (버그 수정 — 설계 사이클 불요)
- approved_by_user: true (2026-08-28 "예전처럼 '작업 기록 필요' 복원 (권장)" 선택)

## 배경

v2.0.0 으로 업데이트한 기존/신규 사용자 프로젝트에서 **모든 Edit/Write/MultiEdit 이 복구 불가로 하드 차단**된다 (`docs/reports/[issues]_2026-08-28.md`). 인과 3단계 (소스 재확인 완료):

1. `active_task` 축이 배포 기본값으로 v2 전환됨 (`rein/engine/authority.py:230` `DEFAULT_SWITCHED_CAPABILITIES`).
2. 위임(`hooks/lib/active-task-gate.sh` `rein_active_task_delegate()`)이 도구별 정책 파일을 **오직** `$PROJECT_DIR/.rein/policy/task-axis/` 에서만 찾고, 없으면 위임을 건너뛴 채 FAIL 로 귀결 (L321-326).
3. FAIL → `hooks/pre-edit-task-gate.sh` 가 v1 폴백 없이 fail-closed exit 2 (L335-343).

이 축 정책은 **이 저장소(dogfood)의 프로젝트 오버라이드로만 존재**했고 (`.rein/policy/task-axis/`, main 제외 대상), **배포본(`plugins/rein-core/`)에는 동봉되지 않았다**. 그래서 dogfood 저장소는 안 막히고 실사용자는 100% 막힌다. `task-axis/_version.yaml` 헤더가 명시한 "번들 기본 세트에 active_task 요구를 정식 반영한 뒤 이 폴더를 제거한다" 는 이관 단계가 v2.0.0 배포 전에 완료되지 않은 것이 근본 원인이다.

## 범위

배포 기본으로 켜진 `active_task` 축이 **오버라이드 없는 프로젝트에서도 정상 위임**되도록 축 정책을 배포본에 동봉하고, 위임이 프로젝트 오버라이드 → 배포본 번들 순으로 정책 위치를 해소하게 한다. 결과: 기존 사용자는 1.6.6 과 동일한 "소스 편집엔 활성 작업 기록 필요" 흐름으로 복원되고, 지금의 복구 불가 차단은 사라진다 (활성 작업이 없으면 여전히 정상 DENY — 이건 의도된 규율, 복구 가능).

포함하지 않음 (의도적 축소):
- 미온보딩 프로젝트 fail-open (사용자가 "복원" 선택 — 거버넌스 기본 켬 유지).
- `policies/default/` 로의 tool.pre 정책 통합 (`_version.yaml` 이 말한 종국 형태 — 더 큰 리팩토링, 별도 후속. 이 hotfix 는 격리 폴더 + REIN_POLICY_DIR 주입 구조를 그대로 두고 폴백 소스만 추가).
- dev 오버라이드 `.rein/policy/task-axis/` 제거 (dogfood 안정성 위해 유지 — 후속 정리 항목).

## 변경 파일

- `plugins/rein-core/policies/task-axis/_version.yaml` (신규 — 배포 번들 정책 버전 메타)
- `plugins/rein-core/policies/task-axis/edit-task.yaml` (신규)
- `plugins/rein-core/policies/task-axis/write-task.yaml` (신규)
- `plugins/rein-core/policies/task-axis/multiedit-task.yaml` (신규)
- `plugins/rein-core/hooks/lib/active-task-gate.sh` (위임 정책 해소를 프로젝트 오버라이드 → 번들 폴백 2단으로 확장 + 해당 주석 갱신)
- `tests/hooks/test-pre-edit-task-gate.sh` (재현/회귀 테스트: 오버라이드 없이 번들 폴백만으로 v2 위임 도달)
- `tests/contract/test_default_policy_matrix.py` 또는 신규 contract 테스트 (배포 번들 task-axis 정책이 존재·로드되고 축 정책과 동일 스키마임을 고정 — 드리프트 가드)

## 검증 기준

- [ ] (red→green) 오버라이드 없는 프로젝트(번들 정책만 존재)에서 소스 Edit → fail-closed exit 2 가 아니라 v2 DENY(활성 작업 없음) 에 도달. 수정 전 이 테스트는 exit 2 로 실패, 후 통과.
- [ ] 배포본 `plugins/rein-core/policies/task-axis/` 3개 도구 정책 + `_version.yaml` 이 존재하고 로더로 파싱됨.
- [ ] 번들 정책 내용(trigger/when/require/failure_mode)이 dogfood 오버라이드·테스트 픽스처와 동일 (드리프트 없음).
- [ ] 기존 task-gate 스위트 전량 초록 (오버라이드 존재 경로 회귀 없음 — 프로젝트 오버라이드가 여전히 우선).
- [ ] 위변조 가드 보존: 프로젝트/번들 **양쪽 모두** 정책 파일이 없을 때만 FAIL(fail-closed).
- [ ] 훅 배터리 전체(`tests/hooks/run-all.sh`) + 영향 contract/unit 테스트 초록.
- [ ] `plugins/rein-core/policies/` 하위 폴더 추가가 기존 정책 로더 격리 계약(`DirectoryIsolationTest`)을 깨지 않음.

## 라우팅 추천

- 버그 수정 — `rein:feature-builder-fix` (reproduction-first: 오버라이드 없는 프로젝트에서 fail-closed 재현 → 번들 폴백으로 green). 구현 후 `rein:codex-review` + `rein:security-reviewer` (게이트 판정 경로·정책 해소 순서 변경이라 fail-closed 방향/우회 표면 확인 필수).

---

approved_by_user: true
