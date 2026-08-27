# DoD — v2 청산 후속 게이트/래퍼 잔재 정리

- date: 2026-08-27 착수
- plan ref: 없음 (설계 사이클 불요 — v2 웨이브 3 ③-d 청산 이후 남은 비차단 잔재 5건의 국소 수정)
- approved_by_user: true (2026-08-27 "제거하자. 나머지 작업 착수해" — 죽은 가드 제거 명시 승인 + 잔재정리 착수 지시)

## 배경

plan 없음 (직접 DoD — 설계 사이클 불요). 전부 v2 웨이브 3 ③-d 이후 게이트 대장에 "비차단 백로그"로 등재된 잔재다. 새 판정 규칙·데이터 흐름 없음 — 문구 교정, 환경 격리, 죽은 코드 제거, 종료값 정직화. plan coverage 매트릭스 대상 아님.

## 범위

1. **옛 훅 이름 잔재 문구 2곳** — 삭제된 `pre-edit-dod-gate` 이름이 실제 출력에 남음: `lib/spec-review-gate.sh:575`(안내문), `lib/incident-review-gate.sh:152`(우회 로그 라벨). 나머지 수십 곳은 역사 서술 주석 — **무변경**.
2-a. **코드리뷰 위임 환경 격리 — 조사 후 취소 (non-issue).** 다른 축은 위임 호출 라인에 인라인 env prefix 로만 `REIN_POLICY_DIR` 주입(export 안 함) → code_review 가 상속받을 경로가 없다. 기존 테스트가 "code-review-gate 는 `REIN_POLICY_DIR` 를 참조하지 않는다"를 계약으로 이미 가드. 백로그 진단이 과대했다 — 변경 없음.
2-b. **죽은 가드 제거** — `REIN_GATE_SOURCE_ONLY` 조기종료 가드의 실제 소비자 0건(전수 확인). 제거 (사용자 승인).
2-c. **빈 경로 오류메시지** — `pre-bash-commit-discipline-gate.sh:393,401` 이 미정의 `$DOD_DIR` 를 빈 문자열로 렌더링. 정의 추가.
3. **래퍼 종료값 정직화 — 별도 사이클로 이월.** `write_code_review_stamp()` 가 발급 실패에도 성공 종료값 반환하는 건 사실이나, 이를 고치면 wrapper 종료코드 계약 확장(신 코드 + 문서 + root 사본 동기화 + 테스트)이 따라와 잔재정리 스코프를 초과한다. codex 가 발견한 리뷰 타임아웃 버그와 함께 "래퍼 계약" 사이클로 이월.

### 제외
- 역사 서술 주석의 옛 훅 이름 (정당한 이력 기록 — 무변경).
- codex 가 발견한 리뷰 타임아웃 버그 (별개 사이클로 이월).

## 변경 파일

- `plugins/rein-core/hooks/lib/spec-review-gate.sh` — 안내문 옛 훅 이름 교정
- `plugins/rein-core/hooks/lib/incident-review-gate.sh` — 우회 로그 라벨 옛 훅 이름 교정
- `plugins/rein-core/hooks/pre-bash-commit-discipline-gate.sh` — REIN_GATE_SOURCE_ONLY 죽은 가드 제거 + DOD_DIR 정의 추가

> 무변경 확정: `code-review-gate.sh`(2-a 취소), `rein-codex-review.sh`(3번 이월), `lib/stamp-parse.sh`(역사 서술 주석 — 삭제된 옛 훅의 과거 동작 기록이라 유지).

## 검증 기준

- [x] 실행 코드에서 삭제된 훅 이름(`pre-edit-dod-gate`) 안내/로그 참조 0건 (역사 주석은 잔존 허용)
- [x] `REIN_GATE_SOURCE_ONLY` 실행 참조 0건 (제거 완료)
- [x] `pre-bash-commit-discipline-gate.sh` 오류메시지가 실제 경로를 렌더링 (DOD_DIR 정의)
- [x] hook 문법 검사(`bash -n`) 통과 + hook 테스트 전체 GREEN (ALL SUITES PASSED)
- (취소) 코드리뷰 위임 환경 격리 — non-issue (2-a)
- (이월) 래퍼 발급 실패 종료값 — 별도 사이클 (3번)

## 라우팅 추천

- **rein:feature-builder-fix** (잔재/버그 수정) + **rein:codex-review** + **rein:security-reviewer** (hook 편집 = 보안 표면)

---

approved_by_user: true
