# `.rein/policy/meta-check.yaml` — schema

`plugins/rein-core/hooks/post-edit-meta-check.sh` (G3 run-time advisory) 의
opt-in / opt-out 정책 파일. **파일이 없으면 built-in default `auto`**.

## Schema

Single top-level field:

```yaml
enabled: auto    # or true | false
```

## Effective policy precedence

Higher precedence wins:

1. 활성 DoD `## 라우팅 추천` 의 `meta_check:` field — per-task override
2. `.rein/policy/meta-check.yaml` 의 `enabled` field — per-project override
3. Built-in default — `auto`

## Semantics

| enabled | 동작 |
|---|---|
| `auto` (default) | 활성 DoD `## 변경 파일` 섹션 있으면 mismatch 비교 + advisory. 부재 시 silent skip + stderr 1줄 NOTICE (G3-MC-DOD-MISSING-HINT (a)) |
| `true` | DoD `## 변경 파일` 부재해도 H=∅ 로 강제 비교 — 모든 dirty diff path 가 mismatch 로 advisory 발화 (G3-MC-DOD-MISSING-HINT (b)) |
| `false` | sub-hook 즉시 skip — envelope 0, inbox 0, git invocation 0 (G3-MC-POLICY) |

## 사용자 예시

### 예시 1 — 기본 (auto, 권고)

파일을 만들지 않거나, 다음을 명시:

```yaml
enabled: auto
```

### 예시 2 — 엄격 모드

모든 DoD 가 `## 변경 파일` 섹션을 채울 것을 기대하는 팀 운영:

```yaml
enabled: true
```

### 예시 3 — 비활성

experimental 단계에서 advisory off:

```yaml
enabled: false
```

## fail-open 보장

다음 모든 경로에서 effective = `auto` 로 fallback (sub-hook 가 사용자 정책 파일
오류로 인해 차단되지 않는다):

- 파일 부재
- PyYAML 미설치
- yaml parse 실패 (stderr 1줄 warning + `auto`)
- `enabled` field 누락
- `enabled` 값이 `true` / `false` / `auto` 외 (예: `yes`, `1`)
- top-level 가 dict 가 아님

## DoD override 예시

DoD `## 라우팅 추천` 안에 task-level override:

```yaml
agent: rein:feature-builder
skills: []
mcps: []
security_tier: light
approved_by_user: true
meta_check: false    # 본 작업만 advisory off
```

해당 DoD 가 active 인 동안만 적용. 다른 DoD 활성화 시 자동 해제.

## 관련 Scope ID

- G3-MC-POLICY — 본 schema 의 핵심 contract
- G3-MC-DOD-MISSING-HINT (a) / (b) — `auto` / `true` 분기 동작
- G3-MC-FASTPATH — answer mode 에서 본 policy 평가 자체도 skip
