#!/bin/bash
# lib/git-subcommand-model.sh — canonical git subcommand token model (SSOT).
#
# GMF-1 / GMF-2 (docs/specs/2026-06-12-gate-misfire-fixes.md §3.1–3.2). This is
# the single authoritative definition of how rein recognises a `git commit`
# (and `git merge`/`rebase`/`am`) invocation. Three consumers source it so no
# literal is mirrored (drift is structurally impossible):
#
#   1. lib/bash-classifier.sh      — gate trigger (CLASS_NEEDS_TC)
#   2. pre-bash-dispatcher.sh      — state-machine class (_SM_CLASS)
#   3. pre-bash-test-commit-gate.sh — gate-internal command_invokes
#
# Side-effect-free pure definition file (same posture as portable.sh /
# path-policy.sh): it defines ERE constants + one clause-start matcher and runs
# no command and mutates no global state. Sourcing it is idempotent — re-source
# from a second consumer is harmless.
#
# Why a SEPARATE lib (not bash-guard-infra.sh): bash-guard-infra.sh has a heavy
# call contract (BG_GUARD_NAME preset, portable/python-runner/project-dir
# pre-source, bg_infra_init). The lightweight classifier/dispatcher must not pay
# that. safety-guard also sources bash-guard-infra but does NOT use this token
# model (its P10 GIT_COMMIT_PREFIX matcher is out of scope), so putting the
# model there would couple safety-guard to a lib it never reads.

# Known git global options that may appear between `git` and the subcommand.
# Explicit allowlist (spec §3.1) — NOT a generic "-*" wildcard, so that
# `git --bogus commit` / `git -Z commit` (options git itself rejects) are
# conservatively NON-matched rather than over-matched as commit.
#   -C <path> / -c <kv> / --git-dir[=| ]<path> / --work-tree[=| ]<path>
#   -p / --paginate / --no-pager / --no-replace-objects / --bare /
#   --literal-pathspecs
# Token separator is [[:space:]]+ (multiple spaces allowed).
GIT_GLOBAL_OPT='(-C[[:space:]]+[^;&|[:space:]]+|-c[[:space:]]+[^;&|[:space:]]+|--git-dir(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|--work-tree(=[^;&|[:space:]]+|[[:space:]]+[^;&|[:space:]]+)|-p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs)'

# git <zero or more global options> <subcommand> — the prefix up to (and
# including the whitespace before) the subcommand token.
GIT_SUBCMD_PREFIX="git([[:space:]]+${GIT_GLOBAL_OPT})*[[:space:]]+"

# commit detection ERE (GMF-1). `commit` is closed by a shell-token boundary
# (spec §3.1 R2 HIGH — `\b` is forbidden because it fires between `commit` and
# `-graph`, failing to exclude `git commit-graph write`). After `commit` there
# must be a space / shell separator (; | & () / end of string.
#   `\$` survives double-quote interpolation as `$` (end anchor) for grep.
GIT_COMMIT_ERE="${GIT_SUBCMD_PREFIX}commit([[:space:]]|;|\||&|\(|\$)"

# merge/rebase/am exemption ERE (GMF-2): same prefix + subcommand alternation
# + the same shell-token boundary.
GIT_MERGE_ERE="${GIT_SUBCMD_PREFIX}(merge|rebase|am)([[:space:]]|;|\||&|\(|\$)"

# git_clause_invokes "<ERE>" "<command-string>"
#   Return 0 if the ERE matches at a command-clause start in the command
#   string, else 1. Clause start = string/line start, right after a shell
#   separator (`;` `&` `|` `(` `)` `{` and a backtick, incl. the last char of
#   `&&`/`||` and the `)` closing a `case` pattern), or right after a POSIX
#   reserved word that introduces a command (`if` `then` `elif` `else`
#   `while` `until` `do` `!`) standing at a token start. Token shape only,
#   not grammatical position — a mention right after such a token is
#   classified as an invocation (accepted conservative direction). Leading
#   `VAR=value` env assignments and command wrappers (env/sudo/command/
#   nohup/time/exec) are skipped. This is the SAME clause-start model as
#   bash-guard-infra.sh::command_invokes (line 196), so a mention such as
#   `echo "git commit"` / `grep git commit -m x` is correctly non-matched.
#
#   classifier/dispatcher call this directly (they do not source
#   bash-guard-infra.sh); test-commit-gate uses bash-guard-infra's
#   command_invokes with the ERE constants above — both share the same anchor.
git_clause_invokes() {
  local ere="$1" cmd="$2" _bt='`'
  git_model_strip_heredocs "$cmd" | grep -qE \
    "(^|[;&|(){${_bt}]|(^|[[:space:];&|(){${_bt}])(if|then|elif|else|while|until|do|!)[[:space:]]+)[[:space:]]*((env|sudo|command|nohup|time|exec)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(${ere})"
}

# git_model_strip_heredocs <command-string> — stdout 으로 heredoc **본문 줄**을
# 제거한 명령을 방출한다 (여는 줄 자체는 유지 — 절 구조 보존).
#
# GSD-3 (dod-2026-08-05-gate-scope-defects): 매처는 `grep -qE` 행 단위 평가라
# `^` 가 모든 줄머리에 앵커된다. heredoc 으로 파일에 기록될 텍스트의 줄이
# `git commit ...` 로 시작하면 실행 절로 오인됐다 (샌드박스 재현 스크립트
# 작성이 커밋 게이트에 차단된 실측). heredoc 본문은 **데이터**이지 실행 절이
# 될 수 없으므로 매칭 입력에서 소거한다 — 원문은 불변, 소거는 매칭 입력에만.
#
# 어휘 계약 (보수적):
#   - 여는 표식: `<<` 또는 `<<-` + 선택 공백 + 선택 인용부호 + [A-Za-z0-9_]+
#     (here-string `<<<` 는 제외 — 본문 줄이 없다).
#   - **인용·주석 인지** (코드 리뷰 R1 High): 여는 표식 탐지는 문자 단위
#     스캐너가 작은따옴표/큰따옴표/백슬래시/워드 시작 `#` 주석 상태를 추적한
#     상태에서만 수행한다 — `printf '%s' '<<EOF'` 처럼 **인용 문자열 속의**
#     `<<WORD` 가 진짜 heredoc 으로 오인되면 그 뒤의 실제 실행 절이 본문으로
#     소거되는 FN 이 생긴다 (실측 재현·수리). 인용 상태는 줄을 넘어 지속된다
#     (여러 줄 인용 문자열). `$(`/backtick 중첩까지는 해석하지 않는다 — 그
#     안의 `<<` 는 여전히 오인 가능하나, 그 방향의 잔존 오차는 본문 소거
#     (기존 FP 클래스)이지 실행 절 유실이 아니도록 아래 fail-closed 가 막는다.
#   - 본문은 다음 줄부터 종결자 단독 줄까지 (`<<-` 는 선행 탭 허용). 한 줄에
#     여러 heredoc 이 열리면 본문이 순서대로 이어진다 (셸과 동일).
#   - **fail-closed**: 종결자가 끝까지 나타나지 않으면(불완전/비정형 명령)
#     소거를 포기하고 입력을 그대로 방출한다 — 오소거로 실제 실행 절을
#     놓치는 FN 보다 기존 FP 유지가 안전하다.
git_model_strip_heredocs() {
  printf '%s' "$1" | awk -v sq="'" '
    function scan_openers(line,   i, n, c, pc, j, st, q, k, qat) {
      i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1)
        if (in_sq) { if (c == sq) in_sq = 0; i++; continue }
        if (in_dq) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") in_dq = 0
          i++; continue
        }
        # 산술 문맥 `((...))` (코드 리뷰 R2 High): 그 안의 `<<` 는 비트 시프트
        # 연산자다 — heredoc 으로 오인하면 뒤따르는 실행 절이 본문으로
        # 소거된다 (FN, 실측 재현). 산술 안에서는 표식 탐지를 멈춘다.
        if (in_arith > 0) {
          if (c == "(" && substr(line, i + 1, 1) == "(") { in_arith++; i += 2; continue }
          if (c == ")" && substr(line, i + 1, 1) == ")") { in_arith--; i += 2; continue }
          i++; continue
        }
        if (c == "(" && substr(line, i + 1, 1) == "(") { in_arith = 1; i += 2; continue }
        if (c == "\\") { i += 2; continue }
        if (c == sq)   { in_sq = 1; i++; continue }
        if (c == "\"") { in_dq = 1; i++; continue }
        if (c == "#") {
          # 워드 시작에서만 주석 (bash 규칙 근사): 줄 시작 또는 공백/구분자 뒤.
          pc = (i > 1) ? substr(line, i - 1, 1) : ""
          if (pc == "" || pc ~ /[ \t;&|(]/) return
          i++; continue
        }
        if (c == "<" && substr(line, i + 1, 1) == "<" \
            && substr(line, i + 2, 1) != "<" \
            && (i == 1 || substr(line, i - 1, 1) != "<")) {
          j = i + 2
          st = 0
          if (substr(line, j, 1) == "-") { st = 1; j++ }
          while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
          q = ""; qat = 0
          c2 = substr(line, j, 1)
          if (c2 == "\"" || c2 == sq) { q = c2; qat = j; j++ }
          k = j
          while (k <= n && substr(line, k, 1) ~ /[A-Za-z0-9_]/) k++
          if (k > j) {
            if (q != "") {
              # 인용 종결자: 닫는 인용부호까지 **검증하고 소비**해야 한다
              # (R2 High: 미소비 시 in_sq 가 켜진 채 남아 이후 줄의 인용
              # 문자열 속 <<WORD 를 진짜 표식으로 오인 — 실행 절 유실).
              if (substr(line, k, 1) == q) {
                nq++; d[nq] = substr(line, j, k - j); tabs[nq] = st
                i = k + 1; continue
              }
              # 닫는 인용부호 부재 = <<(따옴표)EOF 류 미완 표기 — 표식으로 등록하지
              # 않고, 여는 인용부호부터 일반 문자로 재스캔한다 (셸도 이걸
              # 여는 따옴표로 취급한다 — 인용 상태 전이가 자연히 이어진다).
              i = qat; continue
            }
            nq++; d[nq] = substr(line, j, k - j); tabs[nq] = st
          }
          i = k; continue
        }
        i++
      }
    }
    BEGIN { in_sq = 0; in_dq = 0; in_arith = 0 }
    { orig[NR] = $0 }
    nq > 0 {
      t = $0
      if (tabs[1]) sub(/^\t+/, "", t)
      if (t == d[1]) {
        for (i = 1; i < nq; i++) { d[i] = d[i+1]; tabs[i] = tabs[i+1] }
        nq--
      }
      drop[NR] = 1
      next
    }
    {
      scan_openers($0)
      next
    }
    END {
      if (nq > 0) { for (i = 1; i <= NR; i++) print orig[i] }       # fail-closed
      else { for (i = 1; i <= NR; i++) if (!(i in drop)) print orig[i] }
    }
  '
}

# git_commit_outside_repo_cd <command-string> <project_dir>
#   0 → 이 명령이 아래 **좁은 안전 형태**에 정확히 부합해, 커밋이 리터럴
#       절대경로 `cd` 성공에 종속된 채 저장소 밖에서만 실행됨이 어휘적으로
#       증명된다 (커밋 게이트 면제 — 예: mktemp 샌드박스 재현 스크립트).
#   1 → 증명 불가 — 게이트가 기존대로 판정한다.
#
# GSD-3 사용자 확정 + 코드 리뷰 R1 High 반영 계약 — 면제는 다음 형태 **전부**
# 를 만족할 때만 (하나라도 어긋나면 면제 없음 = 기존 게이트 판정):
#   (1) 명령이 **한 줄**이고 heredoc(`<<`)/입력 리다이렉션(`<`)이 없다.
#   (2) 구분자는 `&&` 만 — `;` `|` `||` 단독 `&` `(` `)` backtick `$` 가
#       어디에도(인용 안 포함) 없다. `;` 는 cd 실패 시에도 뒤 절이 저장소에서
#       실행되고, `||` 는 cd **실패** 경로에서 실행되며, `&` 는 백그라운드로
#       cd 와 절연되고, 인용 속 구분자는 절 경계를 위조한다 (전부 실측 재현
#       — R1 High). `$` 금지는 변수/치환으로 대상이 바뀌는 경로를 통째로
#       닫는다.
#   (3) 첫 절이 `cd <리터럴 절대경로>` 이고 그 경로([A-Za-z0-9_./-], `..`
#       세그먼트 없음, 균형 잡힌 단순 인용 허용)가 **물리 정규화(realpath)
#       후에도** PROJECT_DIR 밖이다 (R2 High: `/tmp/alias → 저장소` symlink
#       가 텍스트 접두사 비교를 통과해 실제 저장소 커밋이 면제됐다 — 실측
#       재현·수리. python3 정규화 실패 시 면제 없음 = fail-closed).
#   (4) 이후 절에 디렉토리 이동(`cd`/`pushd`/`popd`, `builtin`/`command`
#       접두 포함)이 없고, `-C` / `--git-dir` / `--work-tree` / `GIT_DIR` /
#       `GIT_WORK_TREE` 토큰이 명령 어디에도 없다 (`cd /tmp && git -C <repo>
#       commit` 이 현재 저장소를 커밋하는 실측 재현 — R1 High).
#   (5) `git commit` 절이 1개 이상 존재한다 (없으면 면제할 것도 없다 — 1).
git_commit_outside_repo_cd() {
  local cmd="$1" project="$2"

  # (1)+(2) 위험 토큰 전면 거부 — 인용 여부 불문 (인용 속 구분자의 절 경계
  # 위조까지 한 번에 배제). 검사 순서는 비용 낮은 문자 검사 먼저.
  case "$cmd" in
    *$'\n'*|*'<'*|*';'*|*'|'*|*'('*|*')'*|*'`'*|*'$'*) return 1 ;;
  esac
  # 단독 `&` 거부 — `&&` 는 허용: `&&` 를 제거한 잔여에 `&` 가 남으면 거부.
  local _no_and="${cmd//&&/}"
  case "$_no_and" in *'&'*) return 1 ;; esac
  # (4) git 대상 재지정 토큰 거부 (어느 위치든).
  case "$cmd" in
    *'-C '*|*'--git-dir'*|*'--work-tree'*|*'GIT_DIR'*|*'GIT_WORK_TREE'*) return 1 ;;
  esac

  local cd_target
  cd_target=$(GIT_MODEL_COMMIT_CLAUSE_ERE="^[[:space:]]*((env|sudo|command|nohup|time|exec)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(${GIT_COMMIT_ERE})" \
  GIT_MODEL_PROJECT="$project" \
  awk -v sq="'" '
    BEGIN {
      ere = ENVIRON["GIT_MODEL_COMMIT_CLAUSE_ERE"]
      proj = ENVIRON["GIT_MODEL_PROJECT"]
      ok = 0          # (3) 충족 여부 — 첫 절이 리터럴 밖 cd
      commits = 0     # (5) git commit 절 수
      bad = 0
      cdp = ""
    }
    {
      n = split($0, cl, /&&/)
      for (i = 1; i <= n; i++) {
        c = cl[i]
        sub(/^[ \t]+/, "", c)
        sub(/[ \t]+$/, "", c)
        if (c == "") { bad = 1; continue }   # 빈 절 (`&& &&` 류) — 비정형
        if (i > 1 && match(c, /^((builtin|command)[ \t]+)?(cd|pushd|popd)([ \t]|$)/)) {
          bad = 1; continue                  # (4) 후속 디렉토리 이동 금지
        }
        if (match(c, /^cd([ \t]+|$)/)) {
          if (i != 1) { bad = 1; continue }  # (4) 후속 cd 금지 (첫 절만 허용)
          arg = substr(c, RLENGTH + 1)
          sub(/^[ \t]+/, "", arg)
          if (arg ~ /[ \t]/) { bad = 1; continue }   # cd 인자 뒤 잔여 토큰 — 비정형
          q = substr(arg, 1, 1)
          if (q == "\"" || q == sq) {
            e = substr(arg, length(arg), 1)
            if (e == q && length(arg) >= 3) arg = substr(arg, 2, length(arg) - 2)
            else { bad = 1; continue }
          }
          if (arg ~ /^\/[A-Za-z0-9_.\/-]+$/ && arg !~ /(^|\/)\.\.(\/|$)/) {
            if (arg == proj || index(arg, proj "/") == 1) bad = 1   # 저장소 안 (텍스트)
            else { ok = 1; cdp = arg }                              # (3) 후보 — 물리 검증은 셸에서
          } else bad = 1
          continue
        }
        if (i == 1) { bad = 1; continue }    # 첫 절이 cd 가 아니면 형태 불충족
        if (match(c, ere)) commits++
      }
    }
    END { if (ok && commits > 0 && !bad) print cdp; exit (ok && commits > 0 && !bad) ? 0 : 1 }
  ' <<< "$cmd") || return 1
  [ -n "$cd_target" ] || return 1

  # (3) 물리 정규화 — symlink 별칭이 저장소를 가리키면 면제 불가 (R2 High).
  # python3 부재/실패 = 증명 불가 → 면제 없음 (fail-closed). 대상 경로가 아직
  # 존재하지 않아도 realpath 는 존재하는 상위 구간의 링크를 해석한다.
  #
  # 연결형 워크트리 판별 (보안 리뷰 2026-08-05 Medium): 이 저장소의 linked
  # worktree 는 경로상(realpath 포함) 저장소 밖이지만, 거기서의 커밋은 공유
  # 객체 DB 와 이 저장소의 브랜치에 실린다 — 즉 이 저장소의 커밋이다 (rein
  # 자체가 워크트리 격리 병렬 패턴을 상용). 대상의 가장 가까운 실존 조상에서
  # `.git` **파일**의 `gitdir:` 값이 이 저장소 안(정규화 기준)을 가리키면
  # 면제하지 않는다. 자체 `.git` 디렉토리를 가진 독립 저장소(진짜 샌드박스)는
  # 영향 없다. 읽기 실패는 면제 없음 (fail-closed).
  python3 -c '
import os, sys
project = os.path.realpath(sys.argv[1])
target = os.path.realpath(sys.argv[2])

def inside(p, root):
    try:
        return os.path.commonpath([root, p]) == root
    except ValueError:
        return False

if inside(target, project):
    sys.exit(1)                      # 저장소 안 → 면제 불가

# 가장 가까운 실존 조상으로 내려가 .git 탐색.
d = target
while not os.path.isdir(d):
    nd = os.path.dirname(d)
    if nd == d:
        break
    d = nd
cur = d
while True:
    g = os.path.join(cur, ".git")
    if os.path.isfile(g):
        try:
            with open(g) as f:
                head = f.read(4096)
        except Exception:
            sys.exit(1)              # 판별 불가 → 면제 없음 (fail-closed)
        for line in head.splitlines():
            if line.startswith("gitdir:"):
                gd = line[len("gitdir:"):].strip()
                if not os.path.isabs(gd):
                    gd = os.path.join(cur, gd)
                if inside(os.path.realpath(gd), project):
                    sys.exit(1)      # 이 저장소의 linked worktree → 면제 불가
        break
    if os.path.isdir(g):
        break                        # 독립 저장소 (자체 .git 디렉토리) → 진짜 밖
    nxt = os.path.dirname(cur)
    if nxt == cur:
        break
    cur = nxt
sys.exit(0)
' "$project" "$cd_target" 2>/dev/null
}
