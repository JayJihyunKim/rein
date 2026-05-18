# hook 비서톤 2단계 — Wave 3 (Phase 3 비서 톤 4표면)

- 날짜: 2026-05-18
- 유형: feat
- plan ref: docs/plans/2026-05-17-hook-message-assistant-tone.md
- DoD: trail/dod/dod-2026-05-17-hook-tone-impl.md

## 변경 파일

- `plugins/rein-core/hooks/pre-bash-guard.sh` — Task 3.1 JSON deny trusted_reason 6건(P2/P3/P4/P5/P6/P11) 비서 톤 마감 + Task 3.4 I1~I6 exit2 stderr 비서 톤 재작성.
- `plugins/rein-core/hooks/stop-session-gate.sh` — Task 3.2 Stop JSON `decision:block` reason + exit2 stderr 비서 톤.
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh` — Task 3.4 exit2 stderr 비서 톤.
- `tests/hooks/test-pre-bash-guard.sh` — 톤 단언 테스트(Suite 7) + companion 단언 2건 갱신(`[Bash guard]`→`[rein]`).
- `tests/hooks/test-pre-bash-guard-coverage-self-heal.sh` — companion 단언 4건 갱신(`unidentifiable`→`could not be identified`).
- `tests/hooks/test-stop-gate-tone.sh` — 신규.
- `tests/hooks/test-exit2-stderr-tone.sh` — 신규 (I1~I5 + I6 톤 검증, codex R1 지적으로 I2/I5 케이스 보강).

## 요약

비서 톤 4표면 중 surface 1/2/4 마감 (surface 3 SessionStart 배너는 Wave 1 Task 3.3 완료분).
전부 message-text-only 변경 — exit code·control flow·reason_code 불변 (spec/codex 가 불변식 확인).
codex-review 2 round (R1 Medium: test-exit2-stderr-tone.sh I2/I5 커버리지 갭 → 보강 → R2 PASS)
+ security-review PASS (Critical/High/Medium/Low 0). spec 준수 리뷰 SPEC-COMPLIANT.
테스트 pre-bash-guard 25·self-heal 9·advisory-coexist 7·commit-msg 23·emitter 15·stop-gate-tone 1·
exit2-stderr-tone 7 통과. bootstrap gate 2종은 stderr 가 helper-captured `$GUIDANCE` 라
in-hook 리터럴 부재 → Phase 3 범위 밖 (미수정이 정답, follow-up tone pass 는 cycle 후보).
다음: Wave 4 (Task 4.1 전체 회귀 + 4.3 versioning v1.3.1).
