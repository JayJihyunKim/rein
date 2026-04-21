# Workflow: add-feature
> 기존 서비스/모듈에 새 기능을 추가할 때 사용

## 실행 절차

### Step 1: 컨텍스트 파악
```
[ ] trail/index.md 읽기
[ ] 변경 대상 디렉토리 현재 패턴 요약
[ ] 관련 테스트 파일 위치 확인
[ ] 의존성 있는 모듈 목록 작성
```

### Step 2: Definition of Done 작성
```markdown
## DoD: [기능명]
- [ ] [기능 동작 조건 1]
- [ ] [기능 동작 조건 2]
- [ ] 기존 테스트 전체 통과
- [ ] 신규 테스트 작성 및 통과
- [ ] lint/format 통과
- [ ] Self-review 완료
```

### Step 3: 작업 계획 (10줄 이내)
```
[ ] 변경할 파일 목록
[ ] 변경 순서 및 의존성
[ ] 영향 범위 확인
```

### Step 4: 구현
```
[ ] 가장 작은 단위부터 구현 (incremental)
[ ] 각 단계마다 테스트 실행
[ ] 에러 처리 포함
```

### Step 5: Codex 코드 리뷰 (필수 — 에스컬레이션 규칙 적용)
```
[ ] /codex-review 스킬로 변경된 파일에 대해 리뷰 실행
[ ] codex 실패(에러/타임아웃) 시에만 sonnet 폴백 리뷰 실행
[ ] 리뷰 결과 심각도 판별 후 에스컬레이션 규칙 적용:
    - High 이슈 → 수정 후 codex 재리뷰
    - Medium + 수정 3줄 초과 → codex 재리뷰
    - Medium + 수정 3줄 이하 → sonnet 셀프리뷰
    - Low만 → sonnet 셀프리뷰
    - 3회차에도 High → 사람 에스컬레이션
[ ] stamp에 reviewer, review_round, resolution 기록 확인
[ ] .review-pending 삭제 확인
```

### Step 6: 완료 검증
```
[ ] DoD 항목 전체 체크
[ ] Self-review (AGENTS.md §6 기준)
[ ] 빠뜨린 규칙 → trail/incidents/ 초안 작성
[ ] trail/index.md 갱신
```
