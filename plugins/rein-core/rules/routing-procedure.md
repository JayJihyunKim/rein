# 라우팅 추천 — DoD `## 라우팅 추천` 섹션 작성 절차

## 행동 강령

매 DoD 작성 직후 `## 라우팅 추천` YAML 섹션을 채우고 (agent 1 / skills ≤3 / mcps ≤2 + rationale) 사용자에게 검토 요청. 승인 시 `approved_by_user: true` 로 교체. 누락 또는 `false` 시 `pre-edit-dod-gate.sh` 가 첫 Edit/Write 차단 (exit 2).

## YAML 예시

```yaml
## 라우팅 추천

agent: feature-builder
skills:
  - rein:codex-review
mcps:
  - context7
rationale:
  - DoD 변경 파일이 hook 소스 → feature-builder 적합
approved_by_user: false  # 승인 시 true 로 교체
```

## 절차 (5단계)

1. DoD 본문 작성 후 `## 라우팅 추천` 섹션을 위 YAML 형식으로 추가.
2. agent 1 / skills ≤3 / mcps ≤2 + rationale 작성.
3. 사용자에게 추천 제시·검토 요청.
4. 승인 시 `approved_by_user: true` 로 교체.
5. DoD 저장 후 첫 Edit/Write 진행 — gate 통과.

## approved_by_user 의미

- `false` (또는 누락): `pre-edit-dod-gate.sh` 가 Edit/Write 차단 (exit 2).
- `true`: gate 통과 + `.active-dod` 마커 자동 기록.
