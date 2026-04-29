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

## 사용자 안내

이 SKILL 의 결과를 사용자에게 보고할 때 다음 짧은 형식을 **먼저** 출력한다 (CHANGELOG entry 본문 또는 변경 분류 메타데이터는 그 다음에 그대로 이어 붙인다). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 액션 1줄.

**성공 (CHANGELOG entry 추가)**:
> CHANGELOG vX.Y.Z entry 추가했습니다. 사용자에게 보이는 변경 N가지 ([핵심 categories — Added / Changed / Fixed / Breaking 중 등장한 것]). 머지 시 README version history 한 줄도 같이 갱신하세요.

**Breaking change 포함**:
> CHANGELOG vX.Y.Z entry 에 Breaking change 가 포함됐어요 — [핵심 1-2건]. 머지 전 사용자 migration 안내 (README 또는 CHANGELOG 의 ⚠️ 섹션) 를 함께 작성하세요.

**No-bump 결정 (internal-only 변경)**:
> 이번 사이클은 internal-only 변경뿐이라 CHANGELOG 갱신을 건너뛰었어요 (`.claude/rules/versioning.md` Rule A no-bump 적용). 버전 tag 도 그대로 유지합니다.
