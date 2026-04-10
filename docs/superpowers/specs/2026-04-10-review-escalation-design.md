# 리뷰 에스컬레이션 설계

> codex 리뷰 후 수정 코드에 대한 재리뷰 규칙 — 무한 루프 방지 + 품질 보장 + 비용 효율

---

## 문제

1. codex 리뷰 → 수정 → 재리뷰 → 수정이 끝없이 반복될 수 있음 (무한 루프)
2. 수정 코드를 리뷰 안 하고 넘어가면 버그가 남음 (품질 누락)
3. 매 수정마다 codex를 돌리면 비용/시간이 과다 (효율성)

## 에스컬레이션 규칙 테이블

```
codex 리뷰 완료
    ↓
이슈 심각도 판별
    ├── High 이슈 있음
    │     → 수정 후 codex 재리뷰 (필수)
    │     → 3회차에도 High 남음 → 사람에게 에스컬레이션
    │
    ├── Medium만 있음
    │     ├── 수정 규모 > 3줄 → codex 재리뷰
    │     └── 수정 규모 ≤ 3줄 → sonnet 셀프리뷰
    │
    ├── Low만 있음
    │     → 수정 후 sonnet 셀프리뷰
    │
    └── 이슈 없음
          → 통과 (stamp 생성)
```

**핵심 규칙:**
- codex 재리뷰 대상: High 이슈, 또는 Medium + 수정 3줄 초과
- sonnet 셀프리뷰 대상: Medium 수정 3줄 이하, Low 전체
- 사람 에스컬레이션: 3회차 리뷰에서도 High 잔존
- stamp에 `review_round: N` 기록하여 몇 번째 리뷰인지 추적

---

## Stamp 메타데이터 확장

```yaml
# SOT/dod/.codex-reviewed
reviewer: codex              # codex | sonnet-fallback | self-review
timestamp: 2026-04-10T15:30:00
fallback_reason: none        # none | codex_timeout | codex_error
files_reviewed: 3
review_round: 2              # 몇 번째 리뷰인지
resolution: passed           # passed | escalated_to_human
remaining_issues: none       # none | "2 medium, 1 low"
```

sonnet 셀프리뷰 시:
```yaml
reviewer: self-review
timestamp: 2026-04-10T16:00:00
fallback_reason: none
files_reviewed: 2
review_round: 2
resolution: passed
remaining_issues: none
prior_reviewer: codex         # 이전 라운드 리뷰어
prior_max_severity: medium    # 이전 라운드 최고 심각도
```

사람 에스컬레이션 시:
```yaml
reviewer: codex
review_round: 3
resolution: escalated_to_human
remaining_issues: "1 high"
```

---

## 변경 파일

| 파일 | 변경 |
|------|------|
| `.claude/skills/codex/SKILL.md` | 리뷰 에스컬레이션 규칙 테이블 + stamp 포맷 확장 + sonnet 셀프리뷰 절차 |
| `AGENTS.md` §5-1 | 리뷰 라운드 규칙 요약 |
| `.claude/workflows/add-feature.md` Step 5 | 리뷰 라운드 절차 반영 |
| `.claude/hooks/pre-bash-guard.sh` | escalated_to_human 감지 시 경고 출력 |
