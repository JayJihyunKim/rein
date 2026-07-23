# 페르소나 변경 시그니처 인사말 — 구현 완료 (dev 커밋만, 미push·미릴리스)

- 날짜: 2026-07-23
- 상태: **구현 + 테스트 + 코드리뷰 + 보안리뷰 완료. dev 커밋 `9e886c3`(구현)·`7c4f8e6`(테스트). 미push·미릴리스.**
- 선행: 같은 날 spec R8 PASS + plan(커버리지 18/18, 설계 재검토 2R PASS). DoD `dod-2026-07-23-persona-change-greeting-impl`.
- 릴리스 등급: **minor (기록만 — 이 사이클 릴리스 안 함, spec §7)**.

## 무엇을 했나

페르소나를 스킬로 **바꾸는 순간** 그 캐릭터 시그니처 인사말 1줄을 상태 보고 앞에 prepend. 세션시작/매턴 훅 소스 불변. 인사말은 프리셋 frontmatter `greeting:` 에 저장, 로더 `--persona-greeting <name>` 로만 읽음.

- 프리셋 boss-ace/jennie 에 curated `greeting:` 필드(summary 공존, ≤60자, tone-only, L4-clean).
- 로더 2벌(byte-identical): `_read_frontmatter_greeting()` 파서, `--persona-greeting` CLI 모드(검증 통과 builtin/custom 만, 무효/오타/traversal → 빈 출력·exit 0, downgrade 재사용 금지=High-1), `_custom_persona_valid()` 에 (P)∧¬(A) fence 거부 강화(newline-preserving read).
- lint (P)∧¬(A) awk-불일치 open fence 거부(fail-closed, `check_body` 이후·`if violations` 이전).
- 스킬 선택/생성 흐름 인사말 명문화(전환 prepend, 중립 평문 1줄, fallback 즉석 생성, 생성 자동 greeting=8번째 질문 없음, 2줄 cap, tone-only 종속).

## 실행 방식 — 2웨이브 병렬 (parallel-execute)

- Wave 1(구현 4 병렬): 프리셋·로더 2벌·스킬·lint. Wave 2(테스트 5 병렬): 로더/lint/스킬/세션시작 회귀 + 신규 preset-greeting.
- 부모(메인 세션)가 웨이브 경계마다 델타 부분집합 검증·파리티·py_compile·테스트 실행·커밋. 워커 edit_only(커밋/스탬프/테스트 실행 금지).

## 리뷰 이력

- **코드리뷰 R1 (codex gpt-5.6-sol, high): NEEDS-FIX** — Medium 1 + Low 1.
  - Medium(실재): `--persona-greeting` "항상 exit 0" 계약이 파일시스템 해석 예외에서 깨짐. `_resolve_persona_file()` 의 `.resolve()`/`is_file()` 가 OSError(5000자 root → ENAMETOOLONG) 던지면 traceback+exit 1. 기존 `--persona-file` 도 같은 잠재 결함(내 신규 분기가 노출).
  - Low/process: 신규 테스트 파일 untracked(커밋 시 해소).
- **수정**: `_resolve_persona_file()` 를 `try:…except Exception: return None` 로 감쌈(로더 2벌) → 세 경로(`--persona`/`--persona-file`/`--persona-greeting`) 모두 fail-open. 정상 경로 byte-identical(동작 불변) 확인. 회귀 테스트 (g12/g13) 추가(5000자 root → 빈출력·exit0).
- **코드리뷰 R2**: codex 워치독이 정지 판정(300s 1차 상한 후 60초 무성장, 390s 경과, exit 5 + 앵커행) → 계약대로 **즉시 Sonnet 대체 리뷰**(재시도 없음). 대체 리뷰(general-purpose/sonnet)가 pre-fix 크래시 재현 + post-fix fail-open + happy-path byte-identical + fence 를 실제 awk 대조 + 전 스위트 재실행으로 **PASS**. stamp: `reviewer: sonnet-fallback`, `fallback_reason: codex_timeout`, round 2.
- **보안리뷰(standard): PASS** — 차단급 0. name boundary(정규식 앵커), fail-open resolver=fail-safe 방향(containment/char-cap 우회 없음), fence 우회 차단, High-1 무누출, 정규식 DoS·코드실행 부재 전부 직접 재현.

## 테스트

로더 56 asserts·lint 24·preset-greeting 2(신규)·skill 45/45·session-start 35/0·turn-brief 12/0(하위호환 (j)/(k) 유지)·3 러너 ALL PASSED. 로더 2벌 diff 빈 출력. py_compile OK.

## 후속 (Low advisory — 비차단, 위협모델 수용, 이번 사이클 미수정)

1. **닫는 fence 느슨 매칭** — `_read_frontmatter_greeting`/L5 는 닫는 fence 를 `.strip()=="---"` 로 느슨 매칭(선두 fence 는 (P)∧¬(A) 로 엄격). 선두 exact + 닫는 padded 인 custom 은 로더가 greeting 방출하나 세션시작 awk 는 본문 통째 삼킴(빈 PRESET_BODY). **기존부터 있던 split(summary/turn-brief 동일)·비회귀·보안영향 없음**. spec 이 (P)∧¬(A) 를 선두 fence 로 한정 → 닫는 fence 확장은 scope creep. follow-up.
2. **로더 greeting 방출에 L4/길이 필터 없음** — L4 스캔·≤60자 캡은 스킬 저장시점 lint 에만. 스킬 우회로 직접 작성/커밋된 custom 은 dirty greeting 통과 가능. 단 본문은 더 강한 채널(세션시작)로 이미 주입·불변층 우선·정직한 에이전트 위협모델 내 수용. 하드닝하려면 로더 방출 직전 L4+길이 캡(정공법). follow-up.

## 관찰

- codex 워치독 정지 판정 **누적 3회 관찰**(user-selection 2회 + 이번 1회). 워치독 설계는 계약대로 작동(exit 5+앵커 → 즉시 대체). codex high effort 리뷰의 실전 완주율이 낮아지는 경향.

## 다음

- 페르소나 영역(사용자 선택 + 변경 인사말)이 이제 dev 에 완결 → **릴리스 시 minor 묶음**(사용자 결정). 워치독 사이클도 미릴리스 상태로 대기 중.
