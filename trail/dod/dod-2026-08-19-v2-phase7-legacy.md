# DoD — v2 Phase 7: Legacy 정리 (Task 7.1)

- date: 2026-08-19 착수
- plan ref: docs/plans/2026-08-08-rein-v2-governance-orchestration.md
- approved_by_user: true (2026-08-19 "Phase 7 진행하자" — Phase 6 종결 직후, 선행 조건 보고 받은 상태에서 진행 지시)
- 선행: Phase 6 전량 완료 (`be0d7b2`/`95f1329`) — 3축 위임 전환 + 2축 이연 종결 + 옛 테스트 안전 분리. 선행 조건 4종은 본 DoD 의 결정 단계(W2)가 소화한다.

## 범위 연결

plan ref: docs/plans/2026-08-08-rein-v2-governance-orchestration.md
covers: [legacy-marker-writes-and-shell-gates-removed-only-after-equivalent-v2-contract-tests-pass, authority-switches-per-capability-with-dual-read-of-legacy-markers, default-policies-require-tests-on-push-not-commit-and-only-when-testing-configured, security-digest-scope-profile-strict-targets-staged-allowlist-complement-and-fails-closed-on-unknown, code-review-evidence-issued-by-runtime-binding-verdict-to-current-digest, masking-engine-serves-both-shadow-sanitization-and-block-log-redaction-as-ssot]

> covers 확장 (2026-08-19, 웨이브 1 리뷰 지적 반영): 선행 결정 1(정책 조건화)·4(기본 전환 축소)의
> 구현이 뒤 두 Scope 의 동작 표면을 실변경하므로 추적 연결에 편입. 첫 Scope(제거)는 후속 웨이브 소관.
> covers 확장 2차 (2026-08-20, 웨이브 3 ③-a 코드 리뷰 1회차 지적 반영): 발급 배선·리뷰 digest 범위
> 구현이 코드리뷰 증거 발급 Scope 의 핵심 구현이므로 추적 연결에 편입.
> covers 확장 3차 (2026-08-25, 웨이브 4 코드 리뷰 1회차 High "coverage/claim drift" 반영):
> 마스킹 SSOT Scope 는 Phase 2 / Task 2.6 에서 **엔진 구현**이 implemented 로 닫혔으나, 그 엔진의
> **소비자 전환**(v1 차단로그 redaction 경로 → 엔진 위임)은 Task 7.1 의 명시 전환 항목으로 남아
> 웨이브 4 가 수행한다. 즉 이 웨이브의 프로덕션 변경과 계약 테스트가 이 Scope 의 소비자 측
> 구현이므로 추적 연결에 편입한다 (plan 매트릭스의 Task 2.6 행은 엔진 구현 기준 그대로 유지 —
> 소비자 전환은 Task 7.1 본문의 "명시 전환·제거 대상" 절이 정본).

## 범위

계획서 Phase 7 Task 7.1 — legacy marker·shell gate 제거. 단, 계획서는 Phase 6 피벗 이전 작성이라
아래 현실 보정을 포함한다 (Phase 6 기록이 정본):

- **설정 등록(hooks.json)이 이 Phase 로 이연됨** (Task 6.1 위임 피벗) — v2 진입점 등록과 v1 게이트
  제거가 한 단계에서 함께 일어난다. 등록 시점이 곧 "v2 기본 정책 의미론이 실발동하는 최초 시점".
- **선행 결정 4종 (구현 착수 전 사용자 결정 필수)**:
  1. 무조건 요구 의미론 — v2 기본 커밋 정책(활성 작업 무관 code_review 요구) 수용 vs v1 의미론
     (활성 작업 없으면 통과) 정책 인코딩. 명시적 동작 변경 결정 (변경 고지 대상).
  2. 스펙 리뷰 표식 의미론 — v2 수용(설계 필요) vs 명시 폐기 (v2 는 해당 표식을 전혀 안 읽음 실측,
     테스트 66건 계열).
  3. 2축(승인·테스트통과) 전환 여부 — push/release 이벤트 관측이 열리는 시점의 활성화 결정 +
     발급 배선 D4 충돌 해소 선행.
  4. 면제 모델 — v1 보안 면제 2종(보안-surface 55케이스 + 경량 등급 15케이스)의 v2 표현. v1 게이트
     제거 시 면제가 함께 사라지면 (a) 문서 커밋 과차단 또는 (b) 보안 요구 누락 — 어느 쪽도 무결정
     통과 불가.
- **비이관 기능 분리 보존** (plan Step 2): 제거 대상 4훅의 v1 존속 겸업 기능(plan-coverage flush·
  커밋 메시지 린팅·명령 분류·안전장치)을 분리 존속 후 제거. Phase 6 선행2 가 일부 분리를 이미 수행
  (공유 라이브러리 6종) — 잔여 겸업 인벤토리는 조사 단계에서 재실측.
- **명시 전환 2건**: 차단 로그 마스킹의 v2 SSOT 소비 전환 + 리뷰 회차 카운터 제거(Loop Controller
  단일화 — 단, 카운터 영속화 계층 미배선 실측(Task 6.3 조사)이라 제거 전 영속화 결정 필요).
- 이관/정화: 차단 로그 대장(blocks.jsonl) + 표식 파일들. v1 병렬 실행 스킬·구 정책 폴더(단수) 재판단.

웨이브: W0 = 진입 게이트(부모 — 전체 스위트 GREEN 재확인 + 게이트 대장 append) → W1 = 결정 재료
조사 (sonnet 워커 3기 병렬, 읽기 전용: ①등록·의미론 실측 ②면제 모델 표현 방안 ③스펙 표식·잔여
겸업 인벤토리) → W2 = 사용자 결정 (결정 매트릭스 제시) → W3 = 구현 (결정 반영 재산정 — 분리 보존·
면제 구현·등록·capability 별 제거 커밋, mutating 은 부모 단독) → W4 = 이관·정화 + 재판단 기록 +
종결 기록.

## 변경 파일

- Modify: `plugins/rein-core/hooks/hooks.json` (v2 진입점 등록 — W2 결정 후)
- Delete: `plugins/rein-core/hooks/pre-edit-dod-gate.sh` / `pre-bash-test-commit-gate.sh` /
  `post-edit-review-gate.sh` / `post-edit-spec-review-gate.sh` (분리 보존 완료 후)
- Modify: `plugins/rein-core/hooks/lib/bash-guard-infra.sh`, `plugins/rein-core/scripts/rein-aggregate-incidents.py` (마스킹 SSOT 소비 전환)
- Modify: `plugins/rein-core/scripts/rein-codex-review.sh` (회차 카운터 — 영속화 결정 따라)
- Create/Modify: v2 정책·capability 파일 (면제 모델 — W2 결정 따라 재산정)
- 이관/정화: `trail/incidents/blocks.jsonl` + `trail/dod/` 표식 파일들
- Modify: `docs/reports/v2-phase-gates.md` (진입·종결 기록)
- 정본 목록: 위는 명시 앵커 — 앵커 외 대상은 Task 6.1 전환 목록 + Task 6.2/6.3 대장에서 도출 (plan 서술 동일)

## 검증 기준

- [ ] W0: 전체 스위트(v1 잔존분 + v2) GREEN 재확인 + 게이트 대장 진입 기록
- [ ] W2: 선행 결정 4종 전부 사용자 결정 기록 (무결정 항목 잔존 시 해당 제거 착수 금지)
- [ ] 제거 전 각 항목의 v2 동등 계약 테스트 GREEN 증빙 게이트 대장 기록 (spec §7)
- [ ] 비이관 겸업 기능 분리 보존 — v1 존속 기능 스위트 GREEN 유지
- [ ] capability 별 제거 커밋 — 각 시점 marker write 경로 grep 0건
- [ ] 명시 전환 2건 완료 (마스킹 SSOT 소비 / 회차 카운터 처리)
- [ ] blocks.jsonl 이관·정화 + 병렬 스킬·구 정책 폴더 재판단 기록
- [ ] 전체 스위트 GREEN + 게이트 대장 종결 기록
- [ ] 웨이브별 코드 리뷰 + 보안 리뷰 통과 후 커밋 (푸시는 사용자 별도 지시까지 보류)

## 선행 결정 4종 확정 (2026-08-19, 사용자 결정 — W2 완료)

1. **커밋 의미론 = 현재 동작 유지, 전용 사실값 방식**: "활성 작업 존재" 를 고정 리터럴("true")로 내는
   전용 fact 신설(테스트 설정 fact 의 기존 선례 재사용, 문법 확장 없음) + 기본 정책 when: 에 조건 추가.
   설계 포인트: (a) 스캐너 오류를 "작업 없음"으로 삼키지 않고 차단 방향으로 전파(fail-open 금지),
   (b) v1 커밋 게이트의 "작업 있음" 술어와 A/B 동등성 테스트 필수(완료-but-파일잔존 틈새 포함).
   **정밀화 (웨이브 1 리뷰 1회차 High 반영)**: fact 술어는 v2 활성작업 스캐너 파생이 아니라 **v1
   커밋 게이트의 파일 존재 검사(글롭) 미러**로 구현한다 — 스캐너 파생은 "완료-but-파일잔존 창"과
   레거시 파일명 클래스에서 위임 경로의 리뷰 요구를 오늘부터 제거하는 실동작 변경임을 리뷰가 재현.
   이 fact 는 v1 의미론 보존 심(shim)이며 v2 관념과의 통일은 v1 게이트 제거 후 별도 결정.
   등록이 무작업 흐름을 새로 차단하지 않도록 조건은 기본 정책의 커밋·push 에 적용하고, release 정책
   처리(무조건 vs 조건)는 구현 시 리뷰에서 명시 판정 — release 게이트는 별도 main 릴리스 결정 항목.
2. **스펙 리뷰 게이트 = 독립 존속**: 관련 훅 2개+도우미를 v1 잔존 기능(커버리지 계열과 동급)으로 유지.
   제거 대상 4훅 중 스펙 게이트 부분만 목표 축소 — 계획서와의 차이 기록.
3. **보안 면제 = 이번에 전부 v2 이관 + 검토 범위 이원화** (모서리 재확인 완료): 판정 재료 신설
   (경량 등급+승인 fact / 버전-only diff fact / "민감 0건 vs 계산 불가" 구분 센티널=D4 해소) + 태그
   규칙 보조. **검토 범위**: 사용자 기본값 = 민감 변경 표적 모델(설계 의도) / 이 저장소 = 모든 커밋
   검토 유지(축 전용 정책 존속 + 면제를 새 판정 재료로 재현). 모서리 B(경량 등급+민감 변경)는 등급
   무관 검토로 **강화 수용**. v1 면제의 staged 기준 vs v2 의 worktree 기준 불일치는 구현 시 staged
   기준으로 정합(커밋 판정의 대상은 staged 분).
   **경량 등급 면제(RT-1) = 명시 폐기** (2026-08-20 사용자 고지·확정 — spec §3.6 의 열거-후-결정
   절차 이행): 확정 의미론(빈 대상=충족 / 판정 불가=보수 미충족 / 실질 변경=등급 무관 요구) 하에서
   RT-1 이 판정을 바꾸는 입력 클래스가 0건 — **6클래스 전수 열거** (digest 상태 × RT-1 선언):
   ① 빈 대상+미선언→충족(차이 없음) ② 빈 대상+선언·승인→충족(RT-1 이 보탤 것 없음) ③ 판정 불가+
   미선언→보수 미충족 ④ 판정 불가+선언·승인→보수 미충족(확인불가≠충족 원칙상 override 비설계)
   ⑤ 실질 변경+미선언→검토 요구 ⑥ 실질 변경+선언·승인→검토 요구(등급 무관 강화 — v1 과 결과가
   다르지만 이는 fact 유무가 아니라 사용자 결정의 적용; RT-1 fact 를 만들어 적용하는 순간 v1 누출
   재도입이라 설계 불가). 전용 판정 재료를 만들지 않고 폐기를 기록으로 남긴다. v1 게이트 제거 시
   해당 로직·테스트 동반 소멸.
   **후속 (Low)**: 진단 CLI(explain)는 아직 프로필 비인지(항상 기본 프로필 기준 출력) — strict
   저장소에서 진단 표시 정확도 갭, 배선 후속. **후속 (결정 후보)**: 정책 버전 fact 의 worktree 읽기와
   프로필 경로의 상태 판정 **통일 여부** — 통일 시도가 미스테이징 픽스처 기반 범위 밖 테스트들을
   회귀시키는 실측으로 이번엔 프로필 경로만 상태 판정 경유. 설계의 정책 파일 커밋 기준화 백로그
   항목과 연계 검토 (리뷰 8회차 지적 반영 명시).
4. **배포 기본값 = 3축 축소**: 기본 전환 목록을 실배선 3축(코드리뷰·보안리뷰·활성작업)으로 좁혀
   미배선 2축의 영구 차단 지뢰 제거. 2축은 발급 배선+충돌 해소 후 편입.
   **파급 명시 수용 (웨이브 1 리뷰 1회차 High 반영)**: 이 축소로 기본 정책 세트의 push(테스트 조건부)·
   release 에서 tests_passed 요구가 재편입 시점까지 **실질 비활성**(자동 충족·전부-미전환 정책은 평가
   사전 필터가 스킵)이다 — 결정 4 의 의도된 결과로 수용하고, authority 활성 기본 경로에서 이 상태를
   고정하는 계약 테스트를 두어 재편입 시 그 테스트 갱신이 강제되게 한다.

부수 채택(권고 그대로, 동작 불변): 리뷰 회차 카운터는 존속(제거 연기 — v2 영속 배선은 별도 사이클) /
등록 방식은 hooks/ 하위 래퍼 스크립트 형태(하네스 호환) / 등록·v1 게이트 제거는 같은 웨이브에서 교대
(위임 이중 평가 방지) / 표식 파싱 헬퍼는 공유 라이브러리로 선행 이전(제거 순서 제약 해소).

## 웨이브 3 구조 확정 (2026-08-20, 사용자 결정 — 한 번에 ③-a→d)

조사 실측 (2026-08-20 읽기 전용 인벤토리): **전환 3축의 v2 판정도 현재 legacy 표식 dual-read 로만
동작** — 증거 발급 함수(issue_code_review_evidence 등)의 프로덕션 호출자 0건, `.review-pending` 은
v1·v2 공용의 유일한 신선도 신호(sole producer = post-edit-review-gate.sh). 따라서 표식 청산(4축
판정 (a)(b))은 발급 배선이 선행 조건. 사용자 결정: 분리하지 않고 이번 웨이브에서 ③-a→d 일괄.

- **③-a 증거 발급 배선**: rein-codex-review.sh PASS 시 + 보안 리뷰 PASS 시 v2 증거 발급 호출
  (전환기 동안 legacy 표식 병행 기록). 신선도의 digest 결속 대체를 계약 테스트로 고정.
- **③-b 편집 게이트 교대 (active_task)**: 존속 겸업 이전용 신설 훅(거버넌스 훼손 차단[본문 인라인
  — lib 부재, 추출 필요]·incident-review·dod-found·spec-review 차단 호출부·routing·log_block/
  ext-source notice ambient·PERF-2 캐시 공급) + v2 1급 래퍼 훅. hooks.json 교대 + pre-edit-dod-gate.sh
  삭제 + pre-edit-coverage-gate.sh 의 peek 결합 보수 + 경로 고정 v1 테스트 재배치. 등록+제거 동일 커밋.
- **③-c 커밋 게이트 교대 (code_review/security_review)**: 존속 겸업 이전용 신설 훅(커버리지 게이트·
  plan-coverage flush·커밋 메시지 린팅·merge/rebase/am 면제 분류) + v2 커밋 래퍼. pre-bash-dispatcher.sh
  테이블 교대 + pre-bash-test-commit-gate.sh 삭제 + v1 판정 lib 3종(code-review/security-review/
  active-task-gate.sh) 제거 — 명령 형태 검사(_sx_ 계열)는 lib 와 동반 소멸(4축 (d) 충족 경로, 조사
  확인: 잔존 사본 0). v2 네이티브 면제(웨이브 2 이관분)가 exemption 대체함을 계약 테스트로 확인.
- **③-d 표식 청산·판정**: post-edit-review-gate.sh 삭제(digest 신선도 대체 확인 후) + rein-codex-review.sh
  의 표식 쓰기 제거 + authority.py 전환기 legacy read(_legacy_*_status) 제거 → 4축 grep 실측 + 게이트
  대장 기록. **존속 예외 명시**: spec-review 표식 계열(결정 2)·`.review-rounds` 회차 카운터(부수 채택
  — 제거 연기)·pre-bash-safety-guard.sh(스코프 외) 는 판정 모집단에서 사유와 함께 제외 기재.
- **로컬 세션 꼬리 공백 수용**: 등록 반영은 세션 시작 스냅샷 — 이 세션 잔여 구간은 구 등록이 삭제
  파일을 가리킴(비차단 훅 오류). 사용자 배포본은 커밋 단위 원자 교대라 공백 없음. 등록 실증은
  선행3 라우팅 검증 하네스(격리 worktree + headless 프로브)로 수행.

## 웨이브 4 결정 확정 (2026-08-25, 사용자 결정)

이관·정화 웨이브의 재판단 3건 + 명시 전환 (2) 처리:

1. **차단 로그 대장 정화 방식 = 안전 표현 재작성** (사용자 결정). 옛 레코드(출처 필드 없음)의
   target 만 교체하고 시각·훅·사유·출처 필드와 레코드 수는 불변으로 둔다 — 반복 경고 집계 수치를
   보존하기 위함(삭제안은 4~8월 반복 패턴 이력과 카운트를 잃는다). 훅 이름이 `pre-bash` 로
   시작하면 명령 모드(동사+내용해시), `pre-edit-dod-gate` 이면 경로 모드. 그 외 훅은 모드를
   추측하지 않고 중단한다(실측 결과 이 두 부류 외 없음). **출처 필드는 추가하지 않는다** —
   부재 = "출처 불명" 이라는 기존 신뢰 규칙과 aggregate 의 통째 치환 동작을 보존해야, 플러그인
   사용자 저장소의 미정화 legacy 레코드가 계속 보호된다.
   **정화 범위 확대 (코드 리뷰 1회차 High 반영)**: 초안은 원시 명령문 제거만 다뤘으나, 경로 모드
   레코드에 다른 머신 사용자명을 포함한 홈 절대경로가 잔존함이 리뷰에서 실측됐다. 저장소의 경로
   정화 SSOT(`rein/shadow/paths.py`)를 데이터 정화와 프로덕션 기록 경로에 적용한다.
   **로컬 raw 로그도 축약 (2026-08-25 사용자 결정, 코드 리뷰 2회차 High 반영)**: 초안은 raw 로그를
   "gitignored 디버깅용" 이라는 이유로 전체 경로 유지했으나, rein 은 사용자 프로젝트에 무시 규칙을
   만들어주지 않는다(실측 0건 — 배포 전 필수 해소 항목으로 이미 등재). 따라서 사용자가 전체 스테이징을
   하면 사용자명·홈 경로가 커밋될 수 있다. 무시 규칙 존재 여부에 의존하지 않도록 raw 로그도 축약한다 —
   자기 홈 위치는 본인이 아는 값이라 진단 손실이 미미하다. 무시 규칙 생성 자체는 사용자 파일을 바꾸는
   동작 변경이라 이번 웨이브가 아니라 배포 사이클 항목으로 유지한다.
2. **v1 병렬 실행 스킬 = 존속** (사용자 결정, spec §5.3 병존 결정의 종결). 근거: v2 대체 자산은
   모듈로 존재하나(`rein/orchestration/` 5모듈) **실행 진입점이 배선되지 않았다** — 프로덕션 코드
   중 이 모듈들을 import 하는 경로 0건, `bin/rein` 에 orchestration 서브커맨드 부재(실측
   2026-08-25). v2 Orchestrator 계약 문서 자체가 v1 스킬 자산을 씨앗으로 재사용한다고 명시한다.
   지금 제거하면 병렬 실행 수단이 소멸한다. **해제 조건**: v2 orchestration 진입점 배선 + 안정화
   확인 후 별도 사이클에서 재판단.
3. **구 정책 디렉토리(단수) = 존속** (사용자 결정, D7 재판단의 종결). 근거: v1 운영 정책 데이터
   (cleanup archive ignore-list)이며 점검·규칙 스킬 2종이 아직 이 경로를 참조한다. v2 기본 policy
   세트(복수 디렉토리)와 의미가 다르므로 한 폴더로 합치면 구분이 흐려진다. **해제 조건**: 두 스킬의
   참조가 사라지거나 ignore-list 자체가 폐기될 때.
4. **명시 전환 (2) 리뷰 회차 카운터 = 존속(제거 연기) 재확인**. 선행 결정의 부수 채택("v2 영속
   배선은 별도 사이클")을 웨이브 4 에서 변경하지 않는다 — Loop Controller 단일화는 영속화 계층
   배선이 선행 조건이며 이번 웨이브 범위 밖이다. 계획서 Task 7.1 의 "카운터 제거" 문구와의 차이를
   여기 기록으로 남긴다.

## 라우팅 추천

approved_by_user: true

- 1순위: `rein:feature-builder` 계열 — 구현 워커는 **sonnet 모델 고정** (사용자 지시 08-11·08-12), 조사·편집 웨이브 병렬 dispatch
- 워커 금지목록: 커밋·스테이징·리뷰 표식·trail 기록·stash 금지, scope 밖 파일 편집 금지, 하위 에이전트 재위임 금지
- 부모(메인 세션): 웨이브 barrier 검증·테스트·리뷰 사이클·제거 커밋·게이트 대장 기록 전담
- 살아있는 훅 편집·삭제는 **격리 worktree 편집 후 원자 반입** (Phase 6 선행2 방식 재사용 — 편집 중간 상태 발화 방지)
