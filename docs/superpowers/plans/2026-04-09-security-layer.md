# Rein Security Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a security review layer to Rein that automatically detects vulnerabilities in AI-generated code through LLM-based review, with progressive security levels and user-level-adaptive feedback.

**Architecture:** Security layer lives in `.claude/security/` with profile, maturity config, and level-based rules. A new `security-reviewer` agent runs after Codex review, gating tests behind a `.security-reviewed` stamp. The existing `pre-bash-guard.sh` hook enforces the gate. `rein init` / `rein new` includes security files by default.

**Tech Stack:** Bash (hooks), YAML (config), Markdown (rules/agent definitions), Shell tests (rein-test.sh)

---

### Task 1: Security Config Files — profile.yaml and maturity.yaml

**Files:**
- Create: `.claude/security/profile.yaml`
- Create: `.claude/security/maturity.yaml`

- [ ] **Step 1: Create profile.yaml**

```yaml
# .claude/security/profile.yaml
# Rein Security Layer — 프로젝트 보안 프로파일
#
# security_level: 현재 적용 중인 보안 규칙 세트
#   - base: 모든 프로젝트 기본 (시크릿, SQLi, XSS 등)
#   - standard: 성숙 프로젝트 (SSRF, Path Traversal, 인증 등)
#   - strict: 프로덕션급 (OWASP Top 10 전항목)
#
# user_level: 보안 피드백 상세도
#   - auto: 상호작용 패턴에서 자동 판별 (기본값 intermediate)
#   - beginner: 자동 수정 + 간단 설명
#   - intermediate: 취약점 설명 + 수정 제안
#   - advanced: 간결 리포트 + 적용/무시/예외등록

security_level: base
user_level: auto
created_at: "2026-04-09"
last_upgraded: "2026-04-09"
snoozed_until: null
upgrade_history: []
```

- [ ] **Step 2: Create maturity.yaml**

```yaml
# .claude/security/maturity.yaml
# Rein Security Layer — 성숙도 엔진 설정
#
# 세션 시작 시 SOT/index.md 읽은 직후 profile.yaml과 함께 체크한다.
# 조건 충족 시 사용자에게 업그레이드를 제안한다.

upgrade_triggers:
  base_to_standard:
    min_conditions: 2
    conditions:
      - metric: commits
        threshold: ">= 50"
        collect: "git rev-list --count HEAD"
      - metric: source_files
        threshold: ">= 30"
        collect: "find src app lib services -type f -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.go' -o -name '*.java' 2>/dev/null | wc -l"
      - metric: external_deps
        threshold: ">= 5"
        collect: "cat package.json requirements.txt pyproject.toml 2>/dev/null | grep -cE '\"[^\"]+\":|==|>='"
      - metric: has_api_endpoints
        threshold: true
        collect: "grep -rlE '(app\\.(get|post|put|delete|patch)|@router|@app\\.route|express\\.Router)' src app lib services 2>/dev/null | head -1"
      - metric: age_days
        threshold: ">= 14"
        collect: "profile.yaml created_at diff"

  standard_to_strict:
    min_conditions: 2
    conditions:
      - metric: commits
        threshold: ">= 200"
        collect: "git rev-list --count HEAD"
      - metric: has_auth
        threshold: true
        collect: "grep -rlE '(auth|login|jwt|session|passport|oauth)' src app lib services 2>/dev/null | head -1"
      - metric: has_database
        threshold: true
        collect: "grep -rlE '(database|\\bdb\\b|sql|orm|prisma|sqlalchemy|mongoose|sequelize)' src app lib services 2>/dev/null | head -1"
      - metric: has_user_input
        threshold: true
        collect: "grep -rlE '(request\\.body|req\\.params|req\\.query|form\\.data|request\\.form)' src app lib services 2>/dev/null | head -1"
      - metric: age_days
        threshold: ">= 30"
        collect: "profile.yaml created_at diff"
```

- [ ] **Step 3: Commit**

```bash
git add .claude/security/profile.yaml .claude/security/maturity.yaml
git commit -m "feat: security layer 프로파일 및 성숙도 설정 파일 생성"
```

---

### Task 2: Base Security Rules

**Files:**
- Create: `.claude/security/rules/base.md`

- [ ] **Step 1: Create base.md**

```markdown
---
level: base
description: 모든 프로젝트에 기본 적용되는 보안 검사 규칙. security-reviewer 에이전트가 이 파일을 컨텍스트로 로드하여 코드를 리뷰한다.
applies_to: "**/*"
---

# Base Security Rules (Level 1)

> 이 파일은 `security-reviewer` 에이전트의 리뷰 기준이다.
> 변경된 코드에 대해 아래 항목을 검사하고, 발견 시 대화형으로 수정을 제안한다.

## 검사 항목

### 1. 시크릿 하드코딩

**탐지 대상:**
- API 키, 비밀번호, 토큰이 소스 코드에 직접 포함된 경우
- 패턴: `api_key = "..."`, `password = "..."`, `token = "..."`, `secret = "..."`
- AWS/GCP/Azure 키 패턴: `AKIA...`, `AIza...`, `-----BEGIN PRIVATE KEY-----`
- 연결 문자열: `postgresql://user:pass@`, `mongodb://user:pass@`

**수정 방향:**
- 환경변수로 분리 (`os.environ`, `process.env`)
- `.env` 파일 사용 (커밋 금지)

### 2. SQL 인젝션

**탐지 대상:**
- 문자열 연결/보간으로 SQL 쿼리를 생성하는 경우
- 패턴: `f"SELECT ... {var}"`, `"SELECT ... " + var`, `` `SELECT ... ${var}` ``
- ORM raw query에 사용자 입력이 직접 삽입되는 경우

**수정 방향:**
- 파라미터화 쿼리 사용 (`cursor.execute("...WHERE id = %s", (id,))`)
- ORM 메서드 사용 (`Model.objects.filter(id=id)`)

### 3. XSS (Cross-Site Scripting)

**탐지 대상:**
- `innerHTML`, `outerHTML`에 사용자 입력이 직접 할당
- `dangerouslySetInnerHTML`에 검증 없는 데이터 사용
- `document.write()` 사용
- 템플릿에서 이스케이프 없이 변수 출력 (`<%- %>`, `{!! !!}`)

**수정 방향:**
- `textContent` 사용 (HTML 아닌 경우)
- DOMPurify 등 sanitization 라이브러리 사용
- 프레임워크 기본 이스케이프 사용 (`{{ }}`, `<%= %>`)

### 4. 안전하지 않은 해싱

**탐지 대상:**
- MD5, SHA1을 비밀번호 해싱에 사용
- 패턴: `hashlib.md5(password)`, `crypto.createHash('md5')`
- salt 없는 해싱

**수정 방향:**
- bcrypt, scrypt, argon2 사용
- 적절한 salt/work factor 적용

### 5. 환경변수 미사용 민감값

**탐지 대상:**
- URL에 인증 정보 포함: `http://user:pass@host`
- 하드코딩된 IP/포트: `127.0.0.1:5432`
- 설정 파일에 직접 기록된 DB 호스트, 포트, 인증 정보

**수정 방향:**
- 환경변수 또는 설정 관리 시스템 사용
- `.env.example`에 키만 포함

## 리뷰 출력 형식

발견된 취약점은 아래 형식으로 보고한다:

```
🔒 [취약점 유형] — [파일:라인]
   [설명]
   수정 제안: [구체적 코드 변경]
```

취약점이 없으면:

```
🔒 보안 리뷰 통과 (Level: base, 대상 파일 N개)
```
```

- [ ] **Step 2: Commit**

```bash
git add .claude/security/rules/base.md
git commit -m "feat: base 보안 규칙 파일 생성 (Level 1)"
```

---

### Task 3: Security Reviewer Agent

**Files:**
- Create: `.claude/agents/security-reviewer.md`

- [ ] **Step 1: Create security-reviewer.md**

```markdown
---
name: security-reviewer
description: 변경된 코드에 대해 현재 보안 레벨 기준으로 취약점을 탐지하고 대화형으로 수정을 제안한다. CODEX REVIEW 완료 후 자동 실행.
---

# security-reviewer

> **역할 한 문장**: 변경된 코드의 보안 취약점을 탐지하고 사용자 레벨에 맞는 대화형 피드백으로 수정을 제안한다.

## 담당
- CODEX REVIEW 완료 후 보안 관점 코드 리뷰
- 보안 레벨(base/standard/strict)에 맞는 규칙 적용
- 사용자 레벨(beginner/intermediate/advanced)에 맞는 피드백 제공
- 보안 리뷰 stamp 생성 (`SOT/dod/.security-reviewed`)

## 담당하지 않는 것
- 일반 코드 품질 리뷰 → `reviewer`
- 기능 구현 → `feature-builder`
- 정적 분석 도구 실행 (LLM 기반 리뷰만 수행)

## 동작 흐름

### 1. 프로파일 로드
```
.claude/security/profile.yaml 읽기
  → security_level: base | standard | strict
  → user_level: auto | beginner | intermediate | advanced
```

### 2. 규칙 로드
```
.claude/security/rules/{security_level}.md 읽기
  → 해당 레벨의 검사 항목을 리뷰 기준으로 사용
```

### 3. 대상 파일 수집
```
git diff --name-only 로 변경된 파일 목록 수집
  → .md, .yaml, .json, .gitkeep 등 설정 파일 제외
  → 소스 코드 파일만 대상
```

### 4. 보안 리뷰 수행
각 파일에 대해 규칙 파일의 검사 항목을 기준으로 취약점 탐지.

### 5. 피드백 전달
user_level에 따라 피드백 상세도를 조절한다:

**beginner** — 자동 수정 + 간단 설명:
```
🔒 위험한 코드를 발견해서 수정했습니다.
   app/api/users.py:23 — 외부 입력이 DB 쿼리에 직접 들어가면
   공격자가 데이터를 훔칠 수 있습니다. 안전한 방식으로 변경할게요.
```

**intermediate** — 취약점 설명 + 수정 제안:
```
🔒 SQL Injection 취약점 발견
   app/api/users.py:23 — f-string으로 쿼리를 조립하면
   사용자 입력에 악의적 SQL이 삽입될 수 있습니다.
   파라미터화 쿼리로 수정을 제안합니다. 적용할까요?
```

**advanced** — 간결 리포트 + 선택지:
```
🔒 SQLi — app/api/users.py:23
   f-string query interpolation. 파라미터화 필요.
   제안: cursor.execute("...WHERE id = %s", (user_id,))
   적용/무시/예외등록?
```

**auto** — 첫 세션에서는 intermediate로 시작. 상호작용 패턴으로 조정:
- "그게 뭔데?" 류 응답 → beginner로 하향
- "적용해" 류 응답 → intermediate 유지
- "이 경우엔 괜찮아" 류 응답 → advanced로 상향

### 6. Stamp 생성
리뷰 완료 후:
```bash
touch SOT/dod/.security-reviewed
```

## 완료 기준
```
[ ] profile.yaml에서 security_level과 user_level을 읽었다
[ ] 해당 레벨의 규칙 파일을 로드했다
[ ] 변경된 소스 코드 파일을 모두 리뷰했다
[ ] 발견된 취약점에 대해 user_level에 맞는 피드백을 제공했다
[ ] SOT/dod/.security-reviewed stamp를 생성했다
```
```

- [ ] **Step 2: Commit**

```bash
git add .claude/agents/security-reviewer.md
git commit -m "feat: security-reviewer 에이전트 정의 파일 생성"
```

---

### Task 4: Hook Modification — Security Stamp Gate

**Files:**
- Modify: `.claude/hooks/pre-bash-guard.sh:46-79` (check_review_stamp 함수)
- Test: `tests/security-hook-test.sh`

- [ ] **Step 1: Write the failing test**

`tests/security-hook-test.sh` 파일을 생성한다:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/.claude/hooks/pre-bash-guard.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_exit_code() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    echo "        expected exit code: $expected"
    echo "        actual exit code:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Setup: fake project structure
setup_project() {
  local dir="$1"
  mkdir -p "$dir/.claude/hooks"
  mkdir -p "$dir/SOT/dod"
  mkdir -p "$dir/SOT/incidents"
  cp "$HOOK" "$dir/.claude/hooks/pre-bash-guard.sh"
  chmod +x "$dir/.claude/hooks/pre-bash-guard.sh"
}

# Run hook with a given command, from a given project dir
run_hook() {
  local project_dir="$1"
  local command="$2"
  local input="{\"tool_input\":{\"command\":\"$command\"}}"
  echo "$input" | (cd "$project_dir" && bash ".claude/hooks/pre-bash-guard.sh") 2>/dev/null
}

# ---------------------------------------------------------------------------
# Test: pytest blocked when DoD exists but no security stamp
# ---------------------------------------------------------------------------
echo ""
echo "Test: pytest blocked without security-reviewed stamp"
proj1="$TEST_DIR/proj1"
setup_project "$proj1"
touch "$proj1/SOT/dod/dod-test-task.md"       # DoD exists
touch "$proj1/SOT/dod/.codex-reviewed"          # Codex stamp exists
# NO .security-reviewed stamp

set +e
run_hook "$proj1" "pytest tests/ -v"
exit1=$?
set -e
assert_exit_code "pytest blocked without security stamp" 2 "$exit1"

# ---------------------------------------------------------------------------
# Test: pytest allowed when both stamps exist
# ---------------------------------------------------------------------------
echo ""
echo "Test: pytest allowed with both stamps"
proj2="$TEST_DIR/proj2"
setup_project "$proj2"
touch "$proj2/SOT/dod/dod-test-task.md"
touch "$proj2/SOT/dod/.codex-reviewed"
touch "$proj2/SOT/dod/.security-reviewed"       # Security stamp exists

set +e
run_hook "$proj2" "pytest tests/ -v"
exit2=$?
set -e
assert_exit_code "pytest allowed with both stamps" 0 "$exit2"

# ---------------------------------------------------------------------------
# Test: git commit blocked without security stamp
# ---------------------------------------------------------------------------
echo ""
echo "Test: git commit blocked without security stamp"
proj3="$TEST_DIR/proj3"
setup_project "$proj3"
touch "$proj3/SOT/dod/dod-test-task.md"
touch "$proj3/SOT/dod/.codex-reviewed"
# NO .security-reviewed stamp

set +e
run_hook "$proj3" "git commit -m \"feat: test commit\""
exit3=$?
set -e
assert_exit_code "git commit blocked without security stamp" 2 "$exit3"

# ---------------------------------------------------------------------------
# Test: no DoD = no stamp check (bypass)
# ---------------------------------------------------------------------------
echo ""
echo "Test: no DoD file = stamps not checked"
proj4="$TEST_DIR/proj4"
setup_project "$proj4"
# NO DoD file, NO stamps

set +e
run_hook "$proj4" "pytest tests/ -v"
exit4=$?
set -e
assert_exit_code "pytest allowed when no DoD exists" 0 "$exit4"

# ---------------------------------------------------------------------------
# Test: expired security stamp blocked
# ---------------------------------------------------------------------------
echo ""
echo "Test: expired security stamp blocked"
proj5="$TEST_DIR/proj5"
setup_project "$proj5"
touch "$proj5/SOT/dod/dod-test-task.md"
touch "$proj5/SOT/dod/.codex-reviewed"
touch "$proj5/SOT/dod/.security-reviewed"
# Make stamp 2 hours old (7200 seconds)
touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$proj5/SOT/dod/.security-reviewed"

set +e
run_hook "$proj5" "pytest tests/ -v"
exit5=$?
set -e
assert_exit_code "pytest blocked with expired security stamp" 2 "$exit5"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/security-hook-test.sh`
Expected: FAIL — hook does not yet check for `.security-reviewed` stamp.

- [ ] **Step 3: Modify pre-bash-guard.sh — add security stamp check**

In `.claude/hooks/pre-bash-guard.sh`, modify the `check_review_stamp` function (lines 47-79). Add a security stamp check after the existing codex stamp check:

Replace the existing `check_review_stamp` function (lines 47-79) with:

```bash
# --- Codex 리뷰 + 보안 리뷰 stamp 공통 검사 함수 ---
check_review_stamp() {
  local context="$1"  # "test" 또는 "commit"
  REVIEW_STAMP="$PROJECT_DIR/SOT/dod/.codex-reviewed"
  SECURITY_STAMP="$PROJECT_DIR/SOT/dod/.security-reviewed"
  DOD_DIR="$PROJECT_DIR/SOT/dod"

  # DoD 파일이 없으면 (작업 중이 아니면) 검사 스킵
  DOD_EXISTS=false
  if [ -d "$DOD_DIR" ]; then
    for f in "$DOD_DIR"/dod-*.md; do
      [ -f "$f" ] || continue
      DOD_EXISTS=true
      break
    done
  fi
  [ "$DOD_EXISTS" = false ] && return 0

  # --- Codex 리뷰 stamp 검사 ---
  if [ ! -f "$REVIEW_STAMP" ]; then
    echo "BLOCKED: Codex 코드 리뷰가 실행되지 않았습니다." >&2
    echo "${context} 전에 /codex 스킬로 코드 리뷰를 실행하세요." >&2
    echo "리뷰 완료 후 SOT/dod/.codex-reviewed 파일이 생성되어야 합니다." >&2
    log_block "Codex 리뷰 미실행 (${context})" "$COMMAND"
    return 1
  fi

  # Codex stamp 만료 검사 (1시간)
  STAMP_AGE=$(( $(date +%s) - $(stat -f %m "$REVIEW_STAMP" 2>/dev/null || stat -c %Y "$REVIEW_STAMP" 2>/dev/null || echo 0) ))
  if [ "$STAMP_AGE" -gt 3600 ]; then
    echo "BLOCKED: Codex 리뷰 stamp가 1시간 이상 경과했습니다. 다시 리뷰를 실행하세요." >&2
    log_block "Codex 리뷰 stamp 만료 (${context})" "$COMMAND"
    return 1
  fi

  # --- 보안 리뷰 stamp 검사 ---
  if [ ! -f "$SECURITY_STAMP" ]; then
    echo "BLOCKED: 보안 리뷰가 실행되지 않았습니다." >&2
    echo "Codex 리뷰 후 security-reviewer 에이전트를 실행하세요." >&2
    echo "리뷰 완료 후 SOT/dod/.security-reviewed 파일이 생성되어야 합니다." >&2
    log_block "보안 리뷰 미실행 (${context})" "$COMMAND"
    return 1
  fi

  # 보안 stamp 만료 검사 (1시간)
  SEC_STAMP_AGE=$(( $(date +%s) - $(stat -f %m "$SECURITY_STAMP" 2>/dev/null || stat -c %Y "$SECURITY_STAMP" 2>/dev/null || echo 0) ))
  if [ "$SEC_STAMP_AGE" -gt 3600 ]; then
    echo "BLOCKED: 보안 리뷰 stamp가 1시간 이상 경과했습니다. 다시 보안 리뷰를 실행하세요." >&2
    log_block "보안 리뷰 stamp 만료 (${context})" "$COMMAND"
    return 1
  fi

  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/security-hook-test.sh`
Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/security-hook-test.sh .claude/hooks/pre-bash-guard.sh
git commit -m "feat: pre-bash-guard에 보안 리뷰 stamp 검사 추가"
```

---

### Task 5: Workflow Documentation Updates

**Files:**
- Modify: `.claude/CLAUDE.md:65-97` (강제 작업 시퀀스)
- Modify: `AGENTS.md:106-112` (역할 목록 테이블)
- Modify: `.claude/orchestrator.md:9-16` (라우팅 테이블)

- [ ] **Step 1: Update CLAUDE.md — 강제 작업 시퀀스에 SECURITY REVIEW 단계 추가**

`.claude/CLAUDE.md`의 "강제 작업 시퀀스" 섹션(line 67~)을 아래로 교체한다:

```markdown
1. **READ** `SOT/index.md` — 항상 첫 번째
2. **WRITE** `SOT/dod/dod-[작업명].md` — 소스 코드 편집 전 필수
   → `pre-edit-dod-gate.sh`가 DoD 파일 없으면 Edit/Write/MultiEdit를 차단함
   → DoD는 inbox과 분리. inbox은 "작업 완료 기록", dod는 "작업 시작 전 기준"
3. **ROUTE** — 스마트 라우터로 최적 조합 추천 → 사용자 확인
   → `.claude/orchestrator.md`의 "스마트 라우팅 절차"를 따른다
   → 세션 컨텍스트에서 사용 가능한 에이전트/스킬/MCP를 동적으로 발견
   → DoD 내용과 description 매칭으로 에이전트 1 + 스킬 최대 3 + MCP 최대 2 추천
   → 사용자 승인 후 다음 단계 진행 (수정 시 overrides.yaml에 기록)
4. **IMPLEMENT** — 승인된 조합의 에이전트/스킬/MCP를 활용하여 소스 코드 편집
5. **CODEX REVIEW** — 구현 완료 후 반드시 Codex로 코드 리뷰 실행
   → `/codex` 스킬로 변경된 파일에 대해 리뷰 요청
   → 리뷰 완료 후 `touch SOT/dod/.codex-reviewed`로 stamp 생성
6. **SECURITY REVIEW** — Codex 리뷰 완료 후 보안 리뷰 실행
   → `security-reviewer` 에이전트가 `.claude/security/profile.yaml`의 보안 레벨 기준으로 리뷰
   → 리뷰 완료 후 `touch SOT/dod/.security-reviewed`로 stamp 생성
   → `pre-bash-guard.sh`가 테스트/커밋 시 두 stamp 모두 없으면 차단함 (exit 2)
7. **FIX** — Codex 리뷰 + 보안 리뷰 결과 반영하여 코드 수정
8. **TEST** — 테스트 실행 (두 리뷰 stamp가 모두 있어야 실행 가능)
9. **SELF-REVIEW** — AGENTS.md §5 항목을 명시적으로 답변
10. **WRITE** `SOT/inbox/YYYY-MM-DD-[작업명].md` — 작업 완료 기록
    → `stop-session-gate.sh`가 세션 종료 시 inbox 기록 없으면 차단함 (exit 2)
    → 라우팅 피드백을 `.claude/router/feedback-log.yaml`에도 기록
11. **UPDATE** `SOT/index.md` — 세션 종료 전
    → `stop-session-gate.sh`가 세션 종료 시 index.md 미갱신이면 차단함 (exit 2)
```

- [ ] **Step 2: Update AGENTS.md — 역할 목록에 security-reviewer 추가**

`AGENTS.md`의 역할 목록 테이블(line 106~112)에 행 추가:

```markdown
| 에이전트 | 역할 | 파일 |
|---------|------|------|
| feature-builder | 신규 기능 구현 전담 | `.claude/agents/feature-builder.md` |
| service-builder | 새 서비스 초기 구조 생성 전담 | `.claude/agents/service-builder.md` |
| reviewer | 코드리뷰 + incident 초안 작성 전담 | `.claude/agents/reviewer.md` |
| researcher | 기술 조사 및 문서 수집 전담 | `.claude/agents/researcher.md` |
| docs-writer | 문서화 및 changelog 작성 전담 | `.claude/agents/docs-writer.md` |
| security-reviewer | 보안 취약점 탐지 및 수정 제안 전담 | `.claude/agents/security-reviewer.md` |
```

- [ ] **Step 3: Update orchestrator.md — 라우팅 테이블에 보안 리뷰 추가**

`.claude/orchestrator.md`의 라우팅 테이블(line 9~16)에 행 추가:

```markdown
| 작업 유형 | Workflow | Agent | 하위 AGENTS.md |
|----------|----------|-------|----------------|
| 새 기능 추가 | `add-feature.md` | `feature-builder` | 해당 언어 디렉토리 |
| 버그 수정 | `fix-bug.md` | `feature-builder` | 해당 언어 디렉토리 |
| 새 서비스 생성 | `build-from-scratch.md` | `service-builder` | 해당 언어 디렉토리 |
| 기술 조사 | `research-task.md` | `researcher` | — |
| 코드 리뷰 | — | `reviewer` | — |
| 보안 리뷰 | — | `security-reviewer` | — |
| 문서 작성 | — | `docs-writer` | — |
```

- [ ] **Step 4: Commit**

```bash
git add .claude/CLAUDE.md AGENTS.md .claude/orchestrator.md
git commit -m "docs: 워크플로우에 SECURITY REVIEW 단계 추가"
```

---

### Task 6: Settings and Rules Updates

**Files:**
- Modify: `.claude/settings.json` (deny 패턴 추가)
- Modify: `.claude/rules/security.md` (base 규칙 참조 추가)

- [ ] **Step 1: Update settings.json — deny 패턴 추가**

`.claude/settings.json`의 `permissions.deny` 배열에 추가:

```json
"deny": [
  "Read(./.env)",
  "Read(./.env.*)",
  "Read(./secrets/**)",
  "Read(~/.ssh/**)",
  "Read(./**/credentials.json)",
  "Read(./**/*.pem)",
  "Read(./**/*.key)"
]
```

- [ ] **Step 2: Update security.md — base 규칙 참조 링크 추가**

`.claude/rules/security.md` 끝에 추가:

```markdown

## Security Layer 연동

보안 레벨별 상세 규칙은 `.claude/security/rules/` 디렉토리에서 관리한다:
- **현재 레벨**: `.claude/security/profile.yaml`의 `security_level` 참조
- **규칙 파일**: `.claude/security/rules/{level}.md`
- 보안 리뷰는 `security-reviewer` 에이전트가 위 규칙을 기준으로 수행한다
```

- [ ] **Step 3: Commit**

```bash
git add .claude/settings.json .claude/rules/security.md
git commit -m "feat: settings.json deny 패턴 강화 및 security.md 연동 추가"
```

---

### Task 7: rein init Integration

**Files:**
- Modify: `scripts/rein.sh:58-71` (COPY_TARGETS 배열)
- Modify: `tests/rein-test.sh` (보안 파일 존재 검증 추가)

- [ ] **Step 1: Write the failing test**

`tests/rein-test.sh`의 "Test: new command" 섹션 뒤(line 138 이후)에 보안 파일 검증을 추가한다:

```bash
# ---------------------------------------------------------------------------
# Test: new command creates security layer files
# ---------------------------------------------------------------------------
echo ""
echo "Test: new command creates security layer files"
assert_file_exists  ".claude/security/profile.yaml exists"             "$project_dir/.claude/security/profile.yaml"
assert_file_exists  ".claude/security/maturity.yaml exists"            "$project_dir/.claude/security/maturity.yaml"
assert_file_exists  ".claude/security/rules/base.md exists"            "$project_dir/.claude/security/rules/base.md"
assert_file_exists  ".claude/agents/security-reviewer.md exists"       "$project_dir/.claude/agents/security-reviewer.md"
assert_file_missing ".claude/security/rules/standard.md should not exist" "$project_dir/.claude/security/rules/standard.md"
assert_file_missing ".claude/security/rules/strict.md should not exist"   "$project_dir/.claude/security/rules/strict.md"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/rein-test.sh`
Expected: FAIL — security files are not yet in COPY_TARGETS, so `rein new` doesn't copy them.

- [ ] **Step 3: Update rein.sh — COPY_TARGETS에 security 디렉토리 추가**

`scripts/rein.sh`의 `COPY_TARGETS` 배열(line 58~71)에 추가:

```bash
COPY_TARGETS=(
  ".claude/CLAUDE.md"
  ".claude/settings.json"
  ".claude/settings.local.json.example"
  ".claude/orchestrator.md"
  ".claude/hooks"
  ".claude/rules"
  ".claude/workflows"
  ".claude/agents"
  ".claude/registry"
  ".claude/skills"
  ".claude/security"
  ".github/workflows"
  "AGENTS.md"
)
```

`.claude/security` 디렉토리 한 줄만 추가하면 하위의 `profile.yaml`, `maturity.yaml`, `rules/base.md`가 모두 복사된다.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/rein-test.sh`
Expected: All tests PASS (기존 + 신규 보안 파일 검증).

- [ ] **Step 5: Commit**

```bash
git add scripts/rein.sh tests/rein-test.sh
git commit -m "feat: rein init에 security layer 파일 포함"
```
