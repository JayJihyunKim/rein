# hook 비서톤 2단계 — Wave 2 (Phase 2 + Task 4.2)

- 날짜: 2026-05-18
- 유형: feat
- plan ref: docs/plans/2026-05-17-hook-message-assistant-tone.md
- DoD: trail/dod/dod-2026-05-17-hook-tone-impl.md

## 변경 파일

- `plugins/rein-core/hooks/pre-bash-guard.sh` — 정책 차단 11지점(P1~P11) `exit 2 + stderr` → `exit 0 + JSON deny` 전환. 인프라 무결성 5지점(I1~I5) `exit 2` 유지. emitter source 직후 신규 `[I6]` fail-closed 가드 추가.
- `plugins/rein-core/hooks/pre-tool-use-bash-rules.sh` — python3 직렬화 실패 시 `|| exit 0` graceful 가드 (advisory hook).
- `tests/hooks/test-pre-bash-guard.sh` — JSON deny 회귀 케이스 + `assert_json_deny` helper + P9/P10/emitter-unavailable 신규.
- `tests/hooks/test-pre-bash-guard-coverage-self-heal.sh` — T2/T6 JSON deny 전환, T3/T4/T7/T8/T9 I3 `exit 2` 유지 주석.
- `tests/hooks/test-bash-rules-advisory-coexist.sh` — 신규 (advisory hook 공존 검증, Case A~E).
- `tests/hooks/test-commit-msg.sh` — P7 회귀 수정 (4 케이스 JSON deny, baseline 5f83022 23/23 → Wave 2 5건 실패 → 복구).
- `docs/reports/2026-05-16-hook-message-json-codex-ask.md` — 2단계 3슬롯 재설계 보존 노트 (Task 4.2).

## 요약

Wave 2 를 2 트랙 병렬 (Phase 2 ∥ Task 4.2) 로 진행. `pre-bash-guard` 정책 차단 11지점을
`exit 0 + JSON deny` 로 전환해 차단 사유가 Claude 경유로 사용자 언어로 전달되게 함.
codex-review 4 round (R1 emitter source fail-open High → R2 가드 우회 High + Korean 보간 →
R3 PASS → R4 PASS, test-commit-msg.sh delta) + security-review PASS (Critical/High 0).
회귀 테스트 전부 통과: pre-bash-guard 24, self-heal 9, advisory-coexist 7, commit-msg 23,
json-deny-emitter 15. 다음: Wave 3 (Task 3.1·3.2·3.4 비서 톤 표면).
