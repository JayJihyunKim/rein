# DoD — 리뷰 증거 기계화 구현 (review evidence manifest)

- date: 2026-07-13
- source: 사용자 요청 (실측 보고서 기반 개선 백로그 1번, "오늘 진행" 지시) + 사용자 결정 4건 (명시 선언+보조 탐지 / 형식만 검증 / 리뷰 전 거부 / 플러그인 기본)

## 범위

codex 리뷰 래퍼에 review-readiness 사전검사를 내장한다: code-review 요청서의 정량/PASS 주장에 증거 블록이 없으면 codex 호출 전에 exit 4 로 거부, 유효 블록은 envelope 구조화 슬롯으로 codex 에 전달. 정량 주장 없는 기존 요청서는 완전 무변경(하위호환). 설계 체인 완료 — spec 5R PASS, plan 7R PASS (표식 생성 완료).

## 범위 연결

plan ref: docs/plans/2026-07-13-review-evidence-manifest.md
work unit: Phase 1~4 전체 (Task 1.1~4.2)
covers: [EV1-valid-blocks-forward-to-codex, EV1-malformed-block-exit4-precodex, EV1-output-over-60-lines-or-8000-bytes-exit4, EV1-block-count-over-16-exit4, EV1-fenced-example-not-parsed, EV2-unbacked-claims-exit4, EV2-claim-free-passthrough-unchanged, EV3-outside-block-flags-advisory, EV3-exclusion-list-suppresses, EV4-spec-mode-skip, EV5-exit-code-contract-preserved, EV6-envelope-claim-audit-crosscheck, EV7-skill-doc-declares-exit4-and-syntax, EV8-mirror-byte-identical, EV9-evidence-suite-and-regressions-green]

## 변경 파일

- plugins/rein-core/scripts/rein-codex-review.sh
- scripts/rein-codex-review.sh
- plugins/rein-core/skills/codex-review/SKILL.md
- tests/skills/test-review-evidence-manifest.sh
- tests/skills/run-all.sh

## 검증 기준

- [ ] plan Task 별 검증 명령 전부 통과 (TDD red→green, `bash -n`, suite GREEN)
- [ ] spec §8 수용 기준 14건 + 인프라 실패 2경로 fixture 전량 GREEN
- [ ] 기존 codex-review 회귀 4종 GREEN + 미러 byte-identical + bundle 테스트 GREEN
- [ ] `/codex-review` 코드 리뷰 게이트 PASS + 보안 리뷰 PASS
- [ ] 하위호환: 정량 주장 없는 요청서의 envelope byte 동일 (EV2-claim-free fixture)

## 라우팅 추천

- 작업 유형: 새 기능 (게이트 래퍼 확장)
- 1순위: plan `## 실행 전략` 대로 — wrapper-engine 과 skill-doc 병렬(scope disjoint), mirror-sync·test-finalize 순차. 호스트 병렬 불가 시 순차 fallback. 구현 유형이므로 `/codex-review` 동반 + 보안 리뷰 (게이트 래퍼 = 보안 민감 표면)
- meta_check: auto

approved_by_user: true  # 사용자가 백로그 1번 당일 진행을 직접 지시 + 설계 결정 4건 승인 (2026-07-13)

## 비고

- 버전: user-facing minor (spec §6). 릴리스는 별도 결정 — index 게이트·trail 위생과 같은 릴리스에 묶일 예정.
- 래퍼 편집은 리뷰 대기 마커를 생성하므로 구현 완료 후 코드 리뷰 게이트 통과가 커밋 전제.
