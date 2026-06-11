# 2026-06-11 — 페르소나/규칙 주입 truncation 수정 (PT-1~PT-12)

## 문제 (사용자 보고 → 실측 검증)

사용자가 rein 업데이트 후 페르소나(boss-ace)가 발동하지 않음. 근본 원인: `session-start-rules.sh` 가 규칙 6종 본문 + 페르소나를 **단일 additionalContext 봉투**(22,592 bytes)로 방출 → Claude Code 하네스가 per-hook cap(10,000자) 초과분을 파일로 빼고 앞 ~2KB 프리뷰만 인라인 → 페르소나(꼬리 byte 20,958~22,592)와 testing/operating-sequence/routing-map/response-tone 전문이 모델에 도달 못 함. 페르소나 미발동은 증상일 뿐, 실제로는 핵심 운영 규칙 주입 자체가 무력화돼 있었음.

## 한 일 (4갈래 + 회귀)

- **요약화(PT-1·2)**: 세션시작이 full body 대신 각 규칙의 `## 행동 강령` 요약(`rules/short/<rule>-summary.md`)을 주입. override → 요약 → full body fallback. rules hook 출력 22.6KB → ~4.8KB.
- **페르소나 격리(PT-3·4·5)**: 페르소나를 독립 hook `session-start-persona.sh`(자체 봉투, loader-검증 preset 이름만 신뢰)로 분리, hooks.json 에 rules 뒤 등재. 조건부(opt-out 무방출).
- **매턴 단일화 + perf(PT-6·7·8)**: loader `--turn-brief` 모드가 매턴 envelope(answer-only+response-tone+persona 요약)를 **단일 python 프로세스**로 방출. 매턴 hook 3 spawn → 1 spawn(persona 추가하면서 오히려 단축). bootstrap guidance 는 env `REIN_TURN_BRIEF_PREPEND` 로 전달.
- **회귀 테스트(PT-9·10·11·12)**: per-hook byte 예산 테스트 신규 + turn-brief loader 테스트 신규 + 요약 전환으로 깨진 기존 테스트 6건 갱신 + parity allowlist.

## 핵심 결정 / 교훈

- **truncation 모델 = per-hook cap**(총합 아님). 실측 근거: 이 사고 세션에서 load-trail(~4.9KB)이 총합 29KB SessionStart 에도 인라인 생존, rules(22.6KB)만 잘림. spec-review 가 "총합 cap 안전" 거짓 주장을 잡아냄 → per-hook 으로 환원.
- **이전 페르소나 릴리스(v1.5.0)의 "매턴 nudge off" 결정을 본 작업이 대체**. truncation 사고가 "세션 1회 주입만으론 도달조차 못 할 수 있다"를 입증 → 매턴 nudge 는 decay 대비가 아니라 도달 보장의 이중 방어.
- **drift checker 무변경**: persona hook 의 존재·실행권한은 generic `check_hooks_json_targets` 가 자동 검증, 동작은 dedicated persona 테스트가 커버 → PT-12 는 parity allowlist 1줄만 실 변경(spec-review R3 가 inert 한 PLUGIN_ONLY_PATHS/EXPECTED_EVENT 추가를 걸러냄).

## 리뷰 (자동 게이트가 실질 결함 다수 포착)

- **spec/plan codex-review 4 round**: HIGH 6건 반영 — 3→1 spawn contract 희석, 총합-cap 거짓 주장, 깨지는 기존 테스트 6건 누락(+PT-12 신설), env fail-open(`os.environ[...]`), per-hook 측정 raw-stdout 분기, drift checker inert 등록. R4 PASS + spec-review 표식 생성.
- **code codex-review 2 round (high effort)**: R1 가 **실제 결함** 포착 — 상속된 `REIN_TURN_BRIEF_PREPEND` 가 매턴 컨텍스트로 누출(프롬프트 주입 벡터). 수정: 호출 시점에 env 명시 지정으로 상속값 가림 + 회귀 테스트 추가. R2 PASS. (초기 1회 PASS 는 thoroughness 부족 — high effort 재실행이 결함 발견.)
- **security review PASS**: path traversal 차단(allowlist+멤버십, `../etc/passwd`·shell-meta 입력 강등 실측), env 주입 차단 실측, 신뢰 경계/fail-open 안전, findings=none.
- **전체 테스트 스위트 green** (tests/hooks + tests/scripts run-all ALL PASSED). 2 loader 사본 byte-identical.

## 상태 / 다음

- **구현 + 리뷰 + 테스트 완료**. dev 미커밋(staged). 버전 bump / 릴리스 / README·CHANGELOG 문서화는 본 작업 **범위 밖**(별도 release cycle — hook 동작 변경이라 Rule A = minor 등급).
- 설계: `docs/specs/2026-06-11-persona-injection-truncation-fix.md`, `docs/plans/2026-06-11-persona-injection-truncation-fix.md`. DoD: `trail/dod/dod-2026-06-11-persona-injection-truncation-fix.md`.
