# Cycle X4.C.4 — SPIKE + Q-1 + (b) + (c) — 영역 C 일시 close

- 날짜: 2026-05-21
- 유형: research + docs + 조건부 config
- 변경 파일:
  - tests/hooks/bench-state-fast-path.sh (NEW, microbenchmark)
  - docs/reports/2026-05-21-area-c-state-machine-spike.md (NEW, SPIKE report)
  - docs/specs/2026-05-21-area-c-state-machine.md (§8.5 X4.C.4 완료, §9 Q-1 answered + Q-5 추가)
  - docs/plans/2026-05-20-integrated-roadmap.md (§4.3 영역 C PARTIAL close, §4.4 영역 D 다음 권장 명시, §5/§5.1 우선순위 정렬)
  - .claude/security/profile.yaml (security_level base → standard upgrade + history)
  - trail/index.md (다음 권장 cycle → 영역 D)
- DoD: trail/dod/dod-2026-05-21-cycle-x4-c-4-spike-area-c-close.md
- 요약:
  - SPIKE 측정 (N=50 x 2 run, macOS Darwin arm64): 영역 C fast-path **PARTIAL** —
    M2 answer-skip 32~33ms 절약 (드문 케이스), M1 +59~77ms / M2 source_edit +66~68ms
    (common case net regression), M3 +1ms (neutral). bench script 가 rc + 5 signal
    (fast-path / envelope / no-envelope / marker-created / marker-touched) 검증.
  - Q-1 (.plan-coverage-dirty vs state.dirty_files): **분리 유지** — 두 layer 가
    action queue (B) vs state query (C) 의 다른 의미 + lifecycle. SPIKE PARTIAL 결과로
    영역 C disable 가능성 보존 위해 영역 B 가 C 에 의존하면 안 됨.
  - (b) state_is_valid / read_effective_mode 2-call TOCTOU: 단일 writer 모델 (memo §4.1)
    하 실질 누출 0. atomic 결합 후 path 별 절감 — M1 ~60-80ms (net -1~+21ms break-even/
    약 회귀), M2 ~30-45ms (회귀 절반 축소, 잔존). X4.C.5 후속 후보.
  - (c) security profile: base → standard upgrade. #7 path traversal 자동 review 가 rein 의
    env-var hook path resolution baseline 강화. #6/#8/#9 는 거의 N/A — false-positive 낮음.
  - 영역 C **일시 close** — SSOT 달성, fast-path PARTIAL. X4.C.5 (atomic 결합, 선택, 영역 D 와
    병렬 가능), X3.B.3 (선택) 잔존. 다음 권장 cycle = **영역 D (release gate + v1.3.3 main 머지)**.
- 리뷰 stamp:
  - codex Mode A code-review: Round 1~3 (Round 3 Low only → self-review, escalation §3)
  - codex Mode A spec-review (design): PASS (R1)
  - codex Mode A spec-review (plan): NEEDS-FIX R1 (High wording overstate, Medium §4.4 dependency
    conflict) → NEEDS-FIX R2 (High trail/index.md drift) → **PASS R3**
  - security-reviewer (standard tier, 9 항목): PASS — 시크릿/SQLi/XSS/hashing/env/deserialize/
    path-traversal/log/TLS 모두 N/A 또는 PASS
- push 없음 (dev-only — 영역 series memory: project_area_series_dev_only_until_complete)
