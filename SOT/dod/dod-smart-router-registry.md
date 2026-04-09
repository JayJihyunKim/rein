# DoD: Smart Router 메타데이터 레지스트리 생성

- 날짜: 2026-04-09
- 유형: feat
- 작업명: smart-router-registry

## 완료 기준 (Definition of Done)

- [ ] `.claude/router/` 디렉토리 생성
- [ ] `.claude/router/overrides.yaml` 생성 (빈 entries 초기화)
- [ ] `.claude/router/feedback-log.yaml` 생성 (빈 entries 초기화)
- [ ] `.claude/router/registry.yaml` 생성 (레이어 1/3/4 전체 메타데이터)
- [ ] YAML 유효성 검증 통과
- [ ] git 커밋 2회 완료

## 검증 방법

```bash
python3 -c "import yaml; yaml.safe_load(open('.claude/router/registry.yaml'))" && echo "YAML valid"
```
