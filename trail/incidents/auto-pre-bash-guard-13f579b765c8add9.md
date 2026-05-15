---
status: "pending"
pattern_hash: "13f579b765c8add9"
hook: "pre-bash-guard"
reason: "coverage-mismatch"
count: "3"
first_seen: "2026-05-15T03:49:06"
last_seen_at: "2026-05-15T03:49:06"
---

# Incident: pre-bash-guard / coverage-mismatch

## 예시 (최근 최대 5건)

```
bash tests/hooks/test-stop-gate.sh 2>&1 | tail -30
timeout 60 bash tests/hooks/test-pre-tool-use-bash-bootstrap-gate.sh 2>&1 | tail -40
rein job start bgi-bash-test -- bash tests/hooks/test-pre-tool-use-bash-bootstrap-gate.sh 2>&1 | tail -5
```

## 분석 메모

(incidents-to-rule 스킬이 분석 결과를 여기에 기록)

## 승격 이력

(사용자 결정 기록)
