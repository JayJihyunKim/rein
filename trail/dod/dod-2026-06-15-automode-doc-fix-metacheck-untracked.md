# DoD — 자동모드 문서 정정 + 메타체크 방치-untracked false-positive 수정

- 날짜: 2026-06-15
- 유형: fix
- Scope ID: AMD-1-automode-doc-scope, MCU-1-metacheck-untracked-window
- 출처: 외부 사용자 제보 → codex-ask 독립 검증 (본 세션)

## 문제 (Symptom)

**AMD-1** — `skills/auto-mode-on/SKILL.md` 가 자동모드 시 "stop-session-gate block 이 모두 silent
처리된다" 고 과장 서술. 실제로는 incident 관련 블록(반복 advisory / 미처리 incident / 3회 초과)에만
`is_auto_mode` 분기가 있고, inbox/index "작업 증거" 종료 차단(`stop-session-gate.sh:467-481`)에는
분기가 없다. 사용자가 자동모드를 켜고도 작업증거 게이트에 막혀 혼란. **버그가 아니라 문서 과장**으로
판정(codex 권고) — 코드는 `lib/auto-mode.sh:4-8` 주석대로 "incident 관련"으로 일관, 문서만 정정한다.

**MCU-1** — `post-edit-meta-check.sh:121-135` 가 `git ls-files --others --exclude-standard` 로
untracked 파일 전체를 D 집합에 합친다. 의도는 "새 Write 파일을 잡기 위함"이나, `.gitignore` 에 안 걸린
오래 방치된 untracked(예: screens_ref/, *.parquet, key_meaning.png)까지 D 에 들어가 "변경 파일 N개 vs
diff M개 불일치" false-positive 경고를 매 편집마다 유발.

## Root cause

- AMD-1: 코드의 자동모드 적용 범위는 처음부터 incident 한정인데, 스킬 문서가 작업증거 블록까지 포함하는
  것처럼 "모두"라고 서술. 코드-문서 불일치.
- MCU-1: untracked 포함 로직이 "이번 세션에 새로 생긴 파일"과 "예전부터 방치된 파일"을 구분하지 않음.

## 범위

- **AMD-1**: `skills/auto-mode-on/SKILL.md` 의 description(3행) + 본문(8행) + 주의(23행)에서 "모든
  stop-session-gate block" 표현을 "incident 관련 stop-session-gate block"으로 정정. `auto-mode-off`
  description 도 parity 로 동일 정정. **코드 무변경.** 작업증거 게이트는 자동모드여도 발동함을 명시.
- **MCU-1**: 메타체크가 untracked 파일을 D 에 합칠 때 "세션 시작 이후 수정된 파일만" 포함하도록
  mtime-window 필터 추가. 앵커 = `trail/incidents/.session-start-line` 스탬프 mtime(세션 시작 시
  1회 기록). 앵커 부재/판독불가 시 **fail-open**(현행대로 전체 untracked 포함 — 새 Write 탐지 보존).
  tracked-modified(`git diff HEAD`) 경로는 무변경.

## 변경 파일

- `plugins/rein-core/skills/auto-mode-on/SKILL.md` — 표현 정정 (AMD-1)
- `plugins/rein-core/skills/auto-mode-off/SKILL.md` — description parity 정정 (AMD-1)
- `plugins/rein-core/hooks/post-edit-meta-check.sh` — untracked mtime-window 필터 (MCU-1)
- `tests/hooks/test-post-edit-meta-check.sh` — 방치 untracked 제외 재현 테스트 (MCU-1)

## 검증 기준

- [ ] failing test 먼저(MCU-1): `test-post-edit-meta-check.sh` 에 "세션 시작 전 mtime 의 방치
      untracked 파일은 mismatch 카운트에 안 들어간다" 케이스 추가 → 현행 코드에서 false-positive 로 실패 확인
- [ ] mtime-window 필터 적용 후 위 케이스 GREEN + "세션 시작 후 새로 Write 된 untracked 는 여전히 잡힘"
      회귀 케이스도 GREEN
- [ ] 앵커 부재 시 fail-open(전체 포함) 동작 케이스 GREEN
- [ ] `bash tests/hooks/test-post-edit-meta-check.sh` 전체 GREEN (기존 + 신규)
- [ ] `bash tests/hooks/test-post-edit-meta-check-perf.sh` GREEN (perf 회귀 없음)
- [ ] AMD-1: `rg '모두 silent|모든 stop-session-gate' plugins/rein-core/skills/auto-mode-*/SKILL.md`
      0건, "incident 관련" 한정 표현으로 교체됨 확인
- [ ] codex review + security review 통과

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  MCU-1 은 reproduction-first 버그수정(메타체크 hook + 그 test). AMD-1 은 동봉된 문서 표현 정정
  (코드 무변경, 동일 PR 범위). 단일 hook + 두 SKILL.md + 한 test 만 touch. codex/security review 와
  integration 은 상위 흐름이 처리하므로 skill/mcp 불필요.
approved_by_user: true
```
