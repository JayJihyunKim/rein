# DoD: 리뷰 워치독 오판 수리 — 자식 명령 대기를 정지로 오인

- 날짜: 2026-07-27
- slug: review-watchdog-false-stall
- 유형: 버그 수정 (사용자 노출 게이트 동작) — 재현 테스트 선행
- 선행 사이클: `trail/inbox/2026-07-27-persona-select-create-entry.md` (오판을 실증한 사이클)
- 신규 spec/plan 문서를 **만들지 않고 기존 문서를 개정**했다 — 근본 원인이 실측으로 확정된 단일 결함 수리. 설계 권위본 `docs/specs/2026-07-22-review-time-cap.md` 의 Scope Items 를 개정하고, 대응 plan `docs/plans/2026-07-22-review-time-cap.md` 에 Phase 5 증분을 추가했다

## 배경 — 실측으로 확정된 오판

워치독은 1차 상한(effort 별 120/180/300초) 이후 30초 창 단위로 **결합 출력이 자라는지**만 보고, 연속 2창(60초) 무성장이면 정지로 판정해 종료한다. 생존 신호가 **단일 축(출력 성장)** 이다.

그런데 codex 는 자식 명령을 실행하는 **동안에는 아무것도 출력하지 않고**, 완료 시점에 결과를 일괄 방출한다. 따라서 리뷰어가 테스트를 돌리면 그 소요만큼 출력 성장이 정확히 0 이 된다.

**실측 (2026-07-27)**:

| 근거 | 값 |
|---|---|
| 실패한 리뷰의 마지막 동작 | `exec /bin/zsh -lc 'bash tests/skills/run-all.sh'` |
| 해당 명령의 실제 소요 | **219초** |
| 종료 시점 | elapsed=360초 (= 300초 상한 + 60초 무성장) |
| SPIKE (`sleep 60` 지시) — 출력 | 604 바이트에서 **45초 이상 정지** |
| SPIKE — 자식 프로세스 수 | 평소 1개 → 명령 실행 중 **3개** |
| SPIKE — 로그 표식 | 시작 `exec` 줄 → 완료 시에야 ` succeeded in 59989ms:` |

→ **codex 는 hang 이 아니라 우리 테스트가 끝나기를 기다리고 있었다.** 리뷰어가 성실히 검증할수록 죽는 역-인센티브이며, 과거 사이클(v1.6.2·v1.6.3 등)에 "codex timeout" 으로 기록된 건들도 동일 원인일 가능성이 있다.

## 범위

1. **생존 신호 2축 추가 (OR 판정)** — 아래 중 **하나라도** 관측되면 그 창은 "활동 있음"으로 계수해 정지 카운터를 리셋한다 (사용자 결정: 둘 다 보되 하나만 있어도 생존):
   - **축 A — 자식 명령 진행 중**: 결합 스풀에서 `exec` 시작 표식 수 > 완료 표식 수. 시작 표식은 `^exec$` 단독 라인 + 다음 라인이 **명령행 구조**(절대경로 프로그램으로 시작 AND 작업 디렉토리 절 포함)일 때만 인정(출력 본문의 우연한 `exec` 문자열 오인 방지, 공백 있는 작업 디렉토리 허용). 완료 표식은 ` succeeded in <N>ms` / ` failed in <N>ms` 형태.
   - **축 B — 자식 프로세스 활동**: 자손 PID 집합이 직전 창과 다르면 **edge**(무기한 유예), 자손이 하나라도 존재하면 **level**(유한 lease 안에서만 유예). 기준선은 **불변 상수 0** — 관측값으로 잡으면 상한 전 시작된 장기 자식이 흡수돼 축 B 가 영구 침묵한다 (설계 리뷰 지적으로 관측 기반 기준선은 폐기).
2. **무성장 허용 확대 + level 유한 lease** — 정지 판정 임계를 연속 2창(60초)에서 **연속 6창(180초)** 으로 확대 (사용자 결정: 순수 추론 구간 보호). level-only 활동은 기본 20창 lease 안에서만 유예해 표식만 남은 hang 이 영구 생존하지 않게 한다. 테스트 전용 override 는 5종으로 확장.
3. **재현 테스트 선행** — 위 오판을 코드로 고정한 뒤 수리한다.
4. **진단 메시지 정정** — 종료 사유에 어떤 축도 활동을 보이지 않았음을 명시 (현행 문구는 출력 성장만 언급).

### 범위 외

- codex 출력 형식 변화에 대한 항구적 대응 — 축 A 가 형식에 의존함은 인지된 한계이며, 형식이 바뀌면 축 B 가 받친다(OR 판정의 목적). 형식 자동 탐지는 하지 않는다.
- 통신 연결 관찰 — 사용자 결정으로 이번엔 채택하지 않음(대기 시간 확대로 대체).
- `tests/skills/run-all.sh` 자체의 219초 소요 단축 — 별개 완화책, 이번 범위 아님.
- 과거 사이클 기록의 소급 재해석 — 후속으로 남긴다.
- 절대 상한 도입 — 현행 "활동이 있으면 무기한 유예" 계약을 유지한다.

## 범위 연결

plan ref: docs/plans/2026-07-22-review-time-cap.md
work unit: Phase 5 / Task 5.1
covers: [watchdog-defers-kill-indefinitely-while-edge-signal-changes-in-30s-windows, watchdog-terminates-codex-after-six-consecutive-inactive-30s-windows-past-cap, watchdog-counts-inflight-child-command-as-activity-within-lease-so-codex-running-tests-is-not-killed, watchdog-bounds-level-only-activity-by-finite-lease-so-stale-marker-hang-still-terminates]

권위 설계본은 `docs/specs/2026-07-22-review-time-cap.md` 이며, 이번 변경으로 Scope Items 2건을 교체하고 2건을 신설했다 (개정 이력 항목 2026-07-27). 기존 plan 에 Phase 5 를 증분으로 추가해 매트릭스와 `covers` 를 정합화했다 (Phase 4 는 이미 다른 작업이 점유).

> 정정 (2026-07-27, 리뷰 R3 지적): 앞선 라운드에서 "신규 plan 을 만들지 않았으므로 정식 `## 범위 연결` 을 쓰면 존재하지 않는 plan 을 가리킨다" 고 기술했으나 **사실이 아니다** — `docs/plans/2026-07-22-review-time-cap.md` 는 실재하며, 갱신 대상이었다. 확인 없이 단정한 오류다.

## 변경 파일

| 파일 | 변경 |
|---|---|
| `plugins/rein-core/scripts/rein-codex-review.sh` | 생존 검진 루프에 축 A/축 B 판정 추가, 정지 임계 2→6창 + override 편입, 종료 진단 문구 정정 |
| `scripts/rein-codex-review.sh` (루트 미러) | 존재 시 동일 반영 — 미러 정합 확인 필수 |
| `tests/skills/test-review-watchdog.sh` | 재현 테스트 + 신규 축 회귀 + 결정론 seam + lease 소진 음성 테스트 |
| `tests/fixtures/fake-codex.sh` | 정지 모드를 안정된 단일 자식으로 교체 + 자식 명령 시뮬레이션 옵션 |
| `docs/specs/2026-07-22-review-time-cap.md` / `docs/plans/2026-07-22-review-time-cap.md` | Scope Items 교체·신설 + 알고리즘·Open Question·테스트 전략 개정 + Phase 5 증분 |
| `plugins/rein-core/skills/codex-review/SKILL.md` | 문서화된 생존 판정·override 목록 갱신 |

## 검증 기준

- [ ] **재현 테스트**: 자식 명령 진행 중(출력 무성장) 상황에서 수리 전 코드가 정지 판정하고, 수리 후에는 살아남는 것을 테스트로 고정한다.
- [ ] 축 A: 시작 표식만 있고 완료 표식이 없으면 활동으로 계수. 완료 표식이 짝을 맞추면 다시 무활동으로 계수.
- [ ] 축 A 오인 방지: 명령 출력 본문에 `exec` 문자열이 섞여도 시작 표식으로 오인하지 않는다.
- [ ] 축 B: PID 집합 변동은 edge, 자손 존재는 level. 기준선은 불변 상수 0 (관측 기반 금지) — 상한 전 시작된 안정 자식이 lease 안에서 완주하는 회귀 테스트로 고정.
- [ ] 진짜 정지(출력·자식 모두 무활동)는 여전히 종료되고 기존 종료 코드·진단 표식 계약이 불변임을 확인한다.
- [ ] 정지 임계가 6창이며 테스트 전용 override 로 조정 가능하다.
- [ ] `bash -n` 통과 + 워치독 관련 기존 테스트 무회귀 + 미러 정합 통과.
- [ ] 코드 리뷰 + 보안 리뷰 통과.

## 라우팅 추천

- agent: 없음 — 메인 세션 직접 구현 (단일 스크립트의 한 함수 + 그 테스트. 위험 경로라 변경 지점을 좁게 유지하는 편이 안전)
- skills: `rein:codex-review`, `rein:security-reviewer`
- mcps: 없음
- rationale: 근본 원인이 실측으로 확정된 좁은 수리. 병렬 분할 이득 없고, 게이트 동작을 바꾸므로 재현 테스트 선행이 핵심

approved_by_user: true
