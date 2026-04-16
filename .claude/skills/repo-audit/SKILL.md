---
name: repo-audit
description: 저장소 전체 상태 점검. 오래된 규칙, 누락 테스트, 비활성 에이전트, trail 일관성 확인.
triggers:
  - 주 1회 (GitHub Actions repo-audit.yml)
  - 수동: "저장소 상태 점검해줘"
---

# Skill: repo-audit

## 점검 항목

### 1. AGENTS.md 규칙 점검
```
[ ] 사용되지 않는 규칙 식별
[ ] 중복 규칙 식별
[ ] 너무 구체적인 숫자 포함 규칙 → 원칙으로 추상화
```

### 2. 에이전트 레지스트리 점검
```
[ ] registry/agents.yml ↔ 실제 파일 일치 여부
[ ] 2주 이상 된 .draft 파일 처리 여부
```

### 3. trail 일관성 점검
```
[ ] trail/index.md 최신 상태 (5~15줄)
[ ] trail/inbox/ 3일 이상 미압축 로그 확인
[ ] trail/incidents/ AGENTS.md 미승격 반복 패턴 확인
```

### 4. 보안 점검
```
[ ] .env 파일 Git 추적 여부
[ ] 하드코딩된 API 키 패턴 검색
[ ] settings.json deny 규칙 최신 여부
```

## 출력 형식
```markdown
# Repo Audit — YYYY-MM-DD
## ✅ 정상
## ⚠️ 개선 권장
## 🚨 즉시 조치 필요
## 제안 액션
```
