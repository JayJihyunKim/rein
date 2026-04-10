# Codex 리뷰 강제 설계

> sub-agent 포함 모든 코드 수정에 codex 리뷰를 하드 강제하고,
> codex 실패 시에만 sonnet 폴백을 허용하는 구조

---

## 문제

1. sub-agent가 코드 수정 후 테스트/커밋을 안 하면 stamp 검사가 트리거되지 않음
2. sub-agent가 메인 에이전트에 결과만 반환하면 리뷰 미검증 상태로 수용됨
3. codex 리뷰 대신 sonnet(자기 자신)이 리뷰하고 stamp를 찍는 경우 발생

## 설계 원칙

- **하드 강제**: hook으로 차단하여 규칙 무시 불가능
- **Codex 우선**: codex 실패(에러/타임아웃) 시에만 sonnet 폴백 허용
- **이중 게이트**: 편집 시점(추적) + 테스트/커밋 시점(차단)
- **리뷰 무효화**: 리뷰 후 추가 코드 수정 시 자동으로 재리뷰 필요

---

## 차단 지점 3개

### 차단 지점 1: PostToolUse(Edit/Write) hook

`post-edit-review-gate.sh` — 소스 코드 편집 시 리뷰 대기 상태 추적

```
PostToolUse(Edit/Write) → post-edit-review-gate.sh
    ├── 편집된 파일이 소스 코드인가?
    │     ├── 아님 (SOT/, docs/) → 패스
    │     └── 맞음 → SOT/dod/.review-pending 생성
    └── 이미 .review-pending 있음 → 아무것도 안 함
```

소스 코드 판별 기준:
- 포함: `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.sh`, `.yml`, `.yaml`, `.json` (settings 등)
- 제외: `SOT/`, `docs/`, `.md` (AGENTS.md 등 규칙 파일)

### 차단 지점 2: PreToolUse(Bash) hook (기존 강화)

`pre-bash-guard.sh` — 테스트/커밋 시 stamp 시간 검증 추가

```
테스트/커밋 명령 감지 시:
    ├── .review-pending 존재 + .codex-reviewed 없음
    │     → exit 2 차단: "코드 변경 후 codex 리뷰가 실행되지 않았습니다"
    ├── .review-pending 존재 + .codex-reviewed 있음
    │     → .codex-reviewed 타임스탬프가 .review-pending보다 최신인지 검증
    │     → 최신이면 통과, 아니면 차단 (리뷰 후 코드 재수정한 경우)
    └── .review-pending 없음 → 기존 로직대로 진행
```

### 차단 지점 3: Sub-agent 프롬프트 규칙 (소프트 강제)

AGENTS.md + 에이전트 정의에 codex 리뷰 필수 규칙 삽입. 규칙을 무시해도 차단 지점 1, 2의 hook에서 잡힘.

---

## Codex 우선 리뷰 + Sonnet 폴백 체인

```
코드 수정 완료
    ↓
codex 스킬 호출 (/codex)
    ├── 성공 → stamp 생성 (reviewer: codex) → .review-pending 삭제
    └── 실패 (에러/타임아웃)
            ↓
        sonnet 폴백 리뷰 (code-reviewer agent, model: sonnet)
            ├── 성공 → stamp 생성 (reviewer: sonnet-fallback, fallback_reason 기록)
            │          → .review-pending 삭제
            └── 실패 → 작업 중단, 사용자에게 보고
```

**sonnet 폴백 허용 조건**: codex가 에러 또는 타임아웃으로 실패한 경우에만. "codex 리뷰 결과가 마음에 안 들어서" 등은 폴백 사유가 아님.

---

## Stamp 메타데이터

현재 빈 파일(`touch`) → 메타데이터 포함 파일로 변경:

```yaml
# SOT/dod/.codex-reviewed
reviewer: codex              # 또는 "sonnet-fallback"
timestamp: 2026-04-10T15:30:00
fallback_reason: none        # 또는 "codex_timeout", "codex_error"
files_reviewed: 3
```

stamp 라이프사이클:
```
코드 편집 → .review-pending 생성
codex 리뷰 → .codex-reviewed 생성 + .review-pending 삭제
또 코드 편집 → .review-pending 재생성 (리뷰 무효화)
```

---

## Sub-agent 규칙 강제

### AGENTS.md 추가 규칙

```
코드 리뷰 필수 규칙 (sub-agent 포함):
- 소스 코드를 수정한 모든 에이전트(sub-agent 포함)는 작업 완료 전 반드시 codex 리뷰를 실행한다
- codex 리뷰: /codex 스킬 호출 → stamp 생성
- codex 실패(에러/타임아웃) 시에만 sonnet 폴백 허용
- sonnet 폴백 시 stamp에 fallback_reason 기록 필수
- 리뷰 없이 결과를 반환하거나 테스트/커밋하면 hook이 차단함
```

### 에이전트 정의 변경

feature-builder.md, service-builder.md 완료 기준에 추가:
```
- [ ] codex 리뷰 실행 완료 (.codex-reviewed stamp 존재)
- [ ] 리뷰 후 추가 수정 시 재리뷰 완료
```

### 워크플로우 변경

add-feature.md의 리뷰 단계를 codex 우선 + sonnet 폴백으로 명시.

---

## 전체 흐름

```
sub-agent 코드 수정 (Edit/Write)
    ↓
[post-edit-review-gate.sh] → .review-pending 생성
    ↓
sub-agent가 /codex 스킬 호출
    ├── 성공 → .codex-reviewed (reviewer: codex), .review-pending 삭제
    └── 실패 → sonnet 폴백 → .codex-reviewed (reviewer: sonnet-fallback), .review-pending 삭제
    ↓
추가 코드 수정?
    ├── 예 → .review-pending 재생성 → 다시 리뷰 필요
    └── 아니오 → 계속
    ↓
테스트/커밋 시도
    ↓
[pre-bash-guard.sh]
    ├── .review-pending + .codex-reviewed 없음 → 차단
    ├── .codex-reviewed가 .review-pending보다 오래됨 → 차단
    └── 정상 → 통과
    ↓
보안 리뷰 → 테스트 → 커밋
```

---

## 변경 파일 목록

| 파일 | 변경 |
|------|------|
| `.claude/hooks/post-edit-review-gate.sh` | 신규 — Edit/Write 후 .review-pending 생성 |
| `.claude/hooks/pre-bash-guard.sh` | 수정 — .review-pending + .codex-reviewed 시간 비교 검증 |
| `.claude/settings.json` | 수정 — PostToolUse에 post-edit-review-gate.sh 등록 |
| `.claude/skills/codex/SKILL.md` | 수정 — 폴백 로직 + stamp 메타데이터 기록 |
| `AGENTS.md` | 수정 — 코드 리뷰 필수 규칙 추가 |
| `.claude/agents/feature-builder.md` | 수정 — 완료 기준에 codex 리뷰 추가 |
| `.claude/agents/service-builder.md` | 수정 — 완료 기준에 codex 리뷰 추가 |
| `.claude/workflows/add-feature.md` | 수정 — codex 우선 + sonnet 폴백 절차 명시 |
