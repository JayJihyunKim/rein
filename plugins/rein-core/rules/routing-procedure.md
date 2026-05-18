# 스마트 라우팅 — DoD `## 라우팅 추천` 섹션 작성 절차

> DoD 작성 직후, 구현 시작 전에 적합한 agent / skill / MCP 조합을 발견·추천·기록하는 절차다.
> 이 문서가 rein 의 라우팅 SSOT 다 — 별도 인벤토리 파일이나 디스크 스캐너에 의존하지 않는다.

## 행동 강령

매 DoD 작성 직후 `## 라우팅 추천` YAML 섹션을 채우고 (agent 1 / skills ≤3 / mcps ≤2 + rationale) 사용자에게 검토 요청. 승인 시 `approved_by_user: true` 로 교체. 누락 또는 `false` 시 `pre-edit-dod-gate.sh` 가 첫 Edit/Write 차단 (exit 2).

---

## 1. 발견 (discovery) — source

라우팅 후보는 **Claude Code 가 매 세션 컨텍스트에 주입하는 목록**에서만 수집한다. 디스크를 스캔하지 않는다.

| 후보 유형 | source | 수집 방법 |
|---|---|---|
| 에이전트 | 세션에 주입된 사용 가능 에이전트 목록 | 이름 + description 수집 |
| 스킬 | `The following skills are available` 목록 (system-reminder) | 이름 + description 수집 |
| MCP | deferred tools 목록의 `mcp__<server>__<tool>` 접두사 + MCP server instructions | `<server>` 식별 + 제공된 instruction 으로 용도 파악 |

- 발견 대상은 **현재 세션에서 실제로 활성화된 capability** 뿐이다 — 세션 목록에 없는 항목은 추천하지 않는다.
- **SKILL.md 본문 blanket pre-scan 금지** — 발견 단계에서 모든 skill 의 `SKILL.md` 본문을 미리 읽지 않는다. description 1줄로 1차 매칭하고, 특정 skill 을 선택·실행할 때 필요하면 그때 progressive disclosure 로 해당 skill 본문만 읽는다.

---

## 2. 신호 추출 — DoD 에서

DoD 파일에서 아래 4가지 신호를 추출한다.

- **키워드**: 작업명, 완료 기준, 요약의 핵심 단어
- **파일 패턴**: 변경 대상 파일의 확장자·경로
- **작업 유형**: add-feature | fix-bug | build-from-scratch | research-task | docs | review 등
- **trail 컨텍스트**: `trail/index.md` 의 현재 상태·블로커

---

## 3. 매칭

발견된 각 후보의 description 텍스트를 DoD 신호와 대조한다.

- description 에서 용도 / 트리거 조건 / 도메인을 읽어 DoD 의 키워드·파일패턴·작업유형과의 관련성을 판단.
- 아래 §5 **기본 권장 조합표**를 1차 기준선으로 삼고, 발견된 실제 capability 로 보정한다 (조합표의 항목이 세션에 없으면 가장 가까운 대체 후보로).

---

## 4. 조합 생성

- **에이전트**: 가장 적합한 1개 (필수)
- **스킬**: 관련성 높은 순 상위 3개까지
- **MCP**: 관련성 높은 순 상위 2개까지

---

## 5. 기본 권장 조합표 (정적 기준선)

작업 유형별 1순위 조합. §3 매칭의 출발점으로 쓰고, 세션 발견 결과로 조정한다.

| 작업 유형 | 에이전트 | 스킬 | MCP |
|---|---|---|---|
| 새 기능 추가 | `rein:feature-builder` | `rein:codex-review` | — |
| 버그 수정 | `rein:feature-builder` | `rein:codex-review`, `superpowers:systematic-debugging` | — |
| 새 모듈·서비스 초기화 | `rein:feature-builder` | `rein:writing-plans`, `rein:codex-review` | — |
| 기술 조사 | `rein:researcher` | — | `context7` |
| plan 작성 | `rein:plan-writer` | `rein:writing-plans` | — |
| 코드 리뷰 | `rein:code-reviewer` | `rein:codex-review` | — |
| 보안 리뷰 | `rein:security-reviewer` | — | — |
| 문서 작성 | `rein:docs-writer` | — | — |
| 아이디어 정제 (brainstorming) | — | `rein:brainstorming` | — |
| 독립 관점 질의 (second opinion) | — | `rein:codex-ask` | — |

> 보안 리뷰는 별도 작업이 아니라 모든 구현 작업의 후행 단계이기도 하다 (`operating-sequence.md` 의 SECURITY REVIEW). 위 표는 "보안 리뷰가 작업의 주 목적인 경우"를 가리킨다.

---

## 6. 사용자 확인 + DoD 기록

추천 조합을 채팅으로 제시하고, 동시에 DoD 파일에 `## 라우팅 추천` 섹션을 기록한다.

채팅 형식:

```
[라우팅] 작업: "[DoD 작업명]"

추천 조합:
  에이전트: [에이전트명]
  스킬:    [스킬1], [스킬2]
  MCP:     [MCP1], [MCP2]

  근거:
  - [매칭 근거 1]
  - [매칭 근거 2]

이 조합으로 진행할까요? (수정하려면 말씀해 주세요)
```

DoD 파일 저장 형식 (필수 — `pre-edit-dod-gate.sh` 가 이 섹션을 검증한다):

```yaml
## 라우팅 추천

agent: rein:feature-builder
skills:
  - rein:codex-review
mcps:
  - context7
rationale:
  - DoD 변경 파일이 hook 소스 → feature-builder 적합
approved_by_user: false  # 승인 시 true 로 교체
```

---

## 7. 수정 사항 기록

사용자가 추천 조합을 수정하면 아래 명령으로 `overrides.yaml` 에 기록한다.

```bash
python3 scripts/rein-route-record.py override \
  --dod trail/dod/dod-YYYY-MM-DD-<slug>.md \
  --removed "skill:foo,mcp:bar" \
  --added "skill:baz" \
  --reason "사용자가 말한 이유"
```

---

## 8. 승인된 조합으로 진행

`approved_by_user: true` 로 교체 후 IMPLEMENT 단계로 이동한다.

작업 완료 시 (= inbox 기록 직후) 아래로 결과 피드백을 남긴다.

```bash
python3 scripts/rein-route-record.py feedback \
  --dod trail/dod/dod-YYYY-MM-DD-<slug>.md \
  --agent rein:feature-builder \
  --skills "rein:codex-review" \
  --mcps "" \
  --outcome success \
  --notes "특이사항"
```

---

## approved_by_user 의미

- `false` (또는 누락): `pre-edit-dod-gate.sh` 가 Edit/Write 차단 (exit 2).
- `true`: gate 통과 + `.active-dod` 마커 자동 기록.

**중요**: `approved_by_user` 는 사용자가 "진행해" 등으로 명시 승인한 뒤에만 `true` 로 설정한다.
