---
name: changelog-writer
description: Git 커밋 히스토리와 trail/decisions/를 기반으로 CHANGELOG.md를 작성한다
triggers:
  - 배포 전 수동 실행
---

# Skill: changelog-writer

## 입력
- Git log (지정 기간 또는 태그 범위)
- `trail/decisions/` — 주요 기술 결정

## 실행 절차

### Step 1: 변경 사항 수집
```bash
git log --oneline [이전태그]..HEAD
```

### Step 2: 분류
- `feat:` → Added
- `fix:` → Fixed
- `refactor:` → Changed
- `BREAKING CHANGE` → Breaking Changes (별도 섹션)

### Step 3: CHANGELOG.md 작성
```markdown
## [버전] - YYYY-MM-DD

### ⚠️ Breaking Changes
### Added
### Changed
### Fixed
### Removed
```

## 완료 기준
```
[ ] 지정 기간 내 모든 feat/fix 변경 포함
[ ] Breaking Changes 별도 표시
[ ] 기술 용어 → 사용자 관점 언어로 변환
[ ] CHANGELOG.md 업데이트
```
