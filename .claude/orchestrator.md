# Orchestrator — 작업 유형별 라우팅 기준

> 작업을 시작할 때 이 파일을 참조해 올바른 workflow + agent 조합을 선택한다.

---

## 라우팅 테이블

| 작업 유형 | Workflow | Agent | 하위 AGENTS.md |
|----------|----------|-------|----------------|
| 새 기능 추가 | `add-feature.md` | `feature-builder` | 해당 언어 디렉토리 |
| 버그 수정 | `fix-bug.md` | `feature-builder` | 해당 언어 디렉토리 |
| 새 서비스 생성 | `build-from-scratch.md` | `feature-builder` | 해당 언어 디렉토리 |
| 기술 조사 | `research-task.md` | `researcher` | — |
| 코드 리뷰 | — | `/codex` 스킬 (fallback: `code-reviewer` 스킬 → `general-purpose`) | — |
| 보안 리뷰 | — | `security-reviewer` | — |
| 문서 작성 | — | `docs-writer` | — |
| plan 작성 | — | `plan-writer` | — |

---

## 작업 유형 판단 기준

### 새 기능 추가 (`add-feature`)
- 기존 서비스/모듈에 새 기능을 추가하는 경우
- 기존 코드를 수정하거나 확장하는 경우

### 버그 수정 (`fix-bug`)
- 예상과 다른 동작을 수정하는 경우
- 에러/예외 처리가 잘못된 경우

### 새 서비스 생성 (`build-from-scratch`)
- 새로운 서비스, 모듈, 앱을 처음부터 만드는 경우
- 디렉토리 구조 자체를 새로 설계하는 경우

### 기술 조사 (`research-task`)
- 라이브러리/프레임워크 비교가 필요한 경우
- 아키텍처 결정을 위한 조사가 필요한 경우

---

## Agent Teams 활용 기준

아래 조건을 모두 충족할 때 Agent Teams(병렬 실행)를 고려한다:
1. 작업이 독립적인 두 개 이상의 서브태스크로 분리 가능
2. 서브태스크 간 의존성이 없거나 명확히 분리됨
3. 컨텍스트 창이 절반 이상 사용된 경우 (컨텍스트 분리 목적)

Agent Teams 사용 시:
- 각 서브 에이전트에게 독립적인 DoD를 부여한다
- 서브 에이전트 결과를 메인 컨텍스트로 가져올 때는 요약본만 포함한다
- 병렬 결과 머지 시 `/codex` 스킬 (fallback: `code-reviewer` 스킬 → `general-purpose` 에이전트) 로 최종 검토한다

---

## 스마트 라우팅 절차

DoD 작성 완료 후, 구현 시작 전에 아래를 수행한다.

### 실행 시점
- **트리거**: DoD 파일(`trail/dod/dod-*.md`) 작성 완료 직후
- **목적**: 현재 환경에서 사용 가능한 에이전트 + 스킬 + MCP 조합을 동적으로 발견하여 추천

### 절차

1. **동적 발견**: 현재 세션에서 사용 가능한 항목을 수집
   - **프로젝트 에이전트**: `.claude/agents/*.md` 파일을 스캔하여 역할 설명 읽기
   - **스킬**: 세션 컨텍스트의 `The following skills are available` 목록에서 이름 + description 수집
   - **MCP**: 세션 컨텍스트의 `deferred tools` 목록에서 `mcp__서버명__` 접두사로 서버 식별
   - **제외**: `.claude/router/registry.yaml`의 `excluded_patterns.description_keywords` 에 매칭되는 스킬(설명문 키워드) 또는 `excluded_patterns.id_globs` 에 매칭되는 id(glob) 를 라우팅 추천에서 제외

2. **신호 추출**: DoD 파일에서 아래 4가지 신호를 추출
   - 키워드: 작업명, 완료 기준, 요약에서 핵심 단어
   - 파일 패턴: 변경 대상 파일의 확장자와 경로
   - 작업 유형: add-feature | fix-bug | build-from-scratch | research-task
   - trail 컨텍스트: `trail/index.md`의 현재 상태, 블로커

3. **매칭**: 발견된 각 항목의 description을 DoD 신호와 대조
   - 각 항목의 description 텍스트에서 용도, 트리거 조건, 도메인을 분석
   - DoD의 키워드/파일패턴/작업유형과의 관련성을 판단
   - `.claude/router/registry.yaml`에 학습된 보정(boost) 데이터가 있으면 반영

4. **조합 생성**:
   - 에이전트: 가장 적합한 1개 (필수)
   - 스킬: 관련성 높은 순 상위 3개까지
   - MCP: 관련성 높은 순 상위 2개까지

5. **사용자 확인 + DoD 기록**: 아래 형식으로 추천 조합을 제시하고, 동시에 DoD 파일에 `## 라우팅 추천` 섹션을 기록한다.

   채팅 형식:
   ```
   [라우팅] 작업: "[DoD 작업명]"

   추천 조합:
     에이전트: [에이전트명] ([워크플로우명])
     스킬:    [스킬1], [스킬2]
     MCP:     [MCP1], [MCP2]

     근거:
     - [매칭 근거 1]
     - [매칭 근거 2]

   이 조합으로 진행할까요? (수정하려면 말씀해 주세요)
   ```

   DoD 파일 저장 형식 (필수 — hook 이 이 섹션을 검증한다):
   ````markdown
   ## 라우팅 추천

   ```yaml
   agent: feature-builder
   skills:
     - codex
     - security-reviewer
   mcps: []
   rationale:
     - 작업 성격: ...
     - 파일 패턴: ...
   approved_by_user: pending   # 사용자 승인 후 true 로 교체
   ```
   ````

   **중요**: `approved_by_user` 값은 사용자가 "진행해" 등으로 명시 승인한 뒤에만 `true` 로 설정한다. `pre-edit-dod-gate.sh` 가 `approved_by_user: true` 없으면 Edit/Write 를 차단한다.

6. **수정 사항 기록**: 사용자가 추천 조합을 수정하면 아래 명령으로 `.claude/router/overrides.yaml` 에 기록
   ```bash
   python3 scripts/rein-route-record.py override \
     --dod trail/dod/dod-YYYY-MM-DD-<slug>.md \
     --removed "skill:foo,mcp:bar" \
     --added "skill:baz" \
     --reason "사용자가 말한 이유"
   ```

7. **승인된 조합으로 작업 진행** (`approved_by_user: true` 로 교체 후 IMPLEMENT 단계로 이동)

### overrides.yaml 기록 형식

```yaml
- date: YYYY-MM-DD
  dod: "dod-[작업명].md"
  pattern:
    keywords: [매칭된 키워드]
    file_patterns: [매칭된 파일 패턴]
    task_type: [작업 유형]
  modification:
    removed: [제거된 항목 id]
    added: [추가된 항목 id]
  reason: "사용자가 말한 수정 이유 (있으면)"
```

### 작업 완료 후 피드백 기록

작업 완료 시(=inbox 기록 직후) 아래 명령으로 `.claude/router/feedback-log.yaml` 에 append 한다:

```bash
python3 scripts/rein-route-record.py feedback \
  --dod trail/dod/dod-YYYY-MM-DD-<slug>.md \
  --agent feature-builder \
  --skills "codex,security-reviewer" \
  --mcps "" \
  --outcome success \
  --notes "특이사항"
```

주기적 또는 세션 종료 시 `python3 scripts/rein-route-record.py learn` 으로 `registry.learned_preferences` 를 갱신한다.

### 자동 보정 규칙

피드백 이력을 분석하여 `.claude/router/registry.yaml`의 `learned_preferences`에 보정 데이터를 축적한다.

| 조건 | 행동 |
|------|------|
| 같은 패턴에서 동일 수정 3회 | 해당 항목에 boost 가산/감산 추가 |
| 특정 조합 성공률 90%+ (5회 이상) | 해당 항목들에 boost +0.2 |
| 특정 조합 실패율 50%+ (3회 이상) | 경고 표시, 해당 항목에 boost -0.2 |

---

## 에이전트 추가 파이프라인

```
trail/incidents/ 축적 (동일 유형 3회 이상)
        ↓
incidents-to-agent SKILL 실행
        ↓ (기준 충족 시)
trail/agent-candidates/{name}.md 생성
        ↓
promote-agent SKILL 실행
        ↓
.claude/agents/{name}.md.draft 생성 + registry 업데이트 초안
        ↓
Human Approval (역할 1문장 + 중복 없음 + DoD 명확)
        ↓
활성화: .draft 제거 + registry 활성화
```
