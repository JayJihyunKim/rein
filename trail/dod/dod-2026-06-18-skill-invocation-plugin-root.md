# DoD — 스킬/규칙/에이전트 문서의 helper 스크립트 호출 경로를 플러그인 루트로 고정

- 날짜: 2026-06-18
- 유형: fix (docs/guidance — 사용자 ship 표면)
- Scope ID: SI-codex-review-skill, SI-code-reviewer-skill, SI-subagent-review-rule, SI-spec-writer-agent, SI-plan-writer-agent
- 출처: 본 세션 진단 — codex-review wrapper 호출이 bare `scripts/...` 상대경로라 repo 루트 복제본(메인테이너 dogfood 에만 존재)으로 떨어짐. 일반 사용자 repo 엔 루트 `scripts/` 부재라 글자 그대로면 깨짐. 같은 패턴이 5개 ship 문서에 분산.

## 문제 (Symptom)

ship 되는 스킬/규칙/에이전트 문서가 helper 스크립트를 `bash scripts/rein-*.sh` (맨앞 경로 없는 상대경로) 로 호출하라고 지시한다. 작업 디렉토리가 repo 루트일 때만 동작하며, 메인테이너 repo 의 루트 `scripts/` 복제본과 플러그인 정본(`${CLAUDE_PLUGIN_ROOT}/scripts/`) 사이에 드리프트가 생기면 낡은 wrapper 로 리뷰가 돌 수 있다. 사용자 repo 엔 루트 `scripts/` 가 없어 글자 그대로 실행 시 실패.

## 범위

5개 문서의 모든 `bash scripts/rein-*.sh` 호출형을 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-*.sh"` 로 정정한다. 플러그인 경로 우선, 변수 미설정 시 `$PWD` 폴백 — 문서화된 resolver 우선순위(플러그인 우선, repo 폴백)와 일치하며 메인테이너 dogfood 도 안 깨진다.

대상 호출 스크립트: `rein-codex-review.sh`, `rein-mark-spec-reviewed.sh`.

### 명시적 비범위
- repo 루트 `scripts/` 복제본 자체의 제거/동기화 장치 (별도 결정 — 본 작업은 호출 표기만 고정).
- 호출이 아닌 순수 서술 프롬 언급(`bash` 접두 없는 경로 멘션)은 손대지 않는다.
- 훅 코드의 resolver(`plugin-script-path.sh`) 변경 없음 — 이미 올바른 우선순위.

## 변경 파일

- plugins/rein-core/skills/codex-review/SKILL.md
- plugins/rein-core/skills/code-reviewer/SKILL.md
- plugins/rein-core/rules/subagent-review.md
- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/agents/plan-writer.md

## 검증 기준

- [ ] 위 5개 파일에서 `bash scripts/rein-` (bare) 잔존 0건
- [ ] 모든 정정 호출이 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-...` 형태
- [ ] `bash` 접두 없는 순수 서술 멘션은 불변
- [ ] 다른 ship 문서에 같은 bare 패턴 신규 유입 0건 (전수 grep)
- [ ] codex 리뷰 통과 (문서 변경이지만 호출 동작 가이던스라 게이트 경로 준수)

## 라우팅 추천

```yaml
agent: docs-writer
skills: []
mcps: []
rationale: >
  ship 문서 5개의 호출 경로 문자열 surgical 정정 (코드 로직 불변). 파일 disjoint 라 병렬 여지 있으나
  변경이 동일 치환 패턴이고 전체 부피가 작아 부모(메인 세션)가 직접 일괄 편집 + 전수 검증이 더 빠르고 안전.
  보안 surface 없음(경로 문자열 가이던스). 부모가 codex 리뷰 + 기록 소유.
approved_by_user: true
```
