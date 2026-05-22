#!/usr/bin/env bash
# State machine library — Cycle X4.C.1 (영역 C, master plan §4.3).
# design ref: docs/specs/2026-05-21-area-c-state-machine.md
#
# Exports (sourced by hooks):
#   acquire_state_lock <mode=x|s>  — flock acquire on .rein/state.lock
#   release_state_lock              — flock release (fd close)
#   read_state                      — parse .rein/state.json → echo JSON, default on absent/malformed
#   write_state <json>              — atomic rename to .rein/state.json
#   append_journal <kind> <payload> — append "<seq>\t<iso-ts>\t<payload>" to .rein/state-pending-<kind>.log
#   read_effective_mode             — state.mode merged with all pending journal entries
#
# Contract (design memo §3.3, §4.2, §4.3):
#   - Single lock: .rein/state.lock used by appender, drain (dispatcher), and reader.
#   - seq monotonic: max(state.last_drain_seq, active max, .processing max) + 1.
#   - Atomic rename for state.json. flock -x for writers, -s acceptable for read-only.
#   - Schema fallback: malformed JSON or unknown schema_version → default + stderr NOTICE.
#
# Shellcheck-clean. POSIX-portable except for `flock` (macOS provides flock via Homebrew
# util-linux; on macOS without flock we degrade to a mkdir-based lock — see helper).

# Idempotent source guard
[ -n "${REIN_STATE_MACHINE_SH_SOURCED:-}" ] && return 0
REIN_STATE_MACHINE_SH_SOURCED=1

# Resolve project dir (allow override for tests + sandboxed hook execution).
_state_machine_project_dir() {
  if [ -n "${REIN_PROJECT_DIR_OVERRIDE:-}" ]; then
    echo "$REIN_PROJECT_DIR_OVERRIDE"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    echo "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Resolve python runner (used for JSON parse). Tests may pre-export PYTHON_RUNNER.
_state_machine_python() {
  if [ -n "${PYTHON_RUNNER:-}" ]; then
    printf '%s\n' "$PYTHON_RUNNER"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo "python"
    return 0
  fi
  return 1
}

_state_machine_paths() {
  local pdir
  pdir=$(_state_machine_project_dir)
  STATE_DIR="$pdir/.rein"
  STATE_FILE="$STATE_DIR/state.json"
  STATE_LOCK="$STATE_DIR/state.lock"
  J_EDITS="$STATE_DIR/state-pending-edits.log"
  J_BASH="$STATE_DIR/state-pending-bash.log"
  J_STOP="$STATE_DIR/state-pending-stop.log"
}

_state_machine_ensure_dir() {
  _state_machine_paths
  if [ ! -d "$STATE_DIR" ]; then
    # 0700 to keep state user-private (memo §2.1).
    mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null || true
  fi
}

# Default state (memo §2.2 schema_version=1).
_state_machine_default_state() {
  cat <<'JSON'
{"schema_version":1,"mode":"answer","updated_at":"","dirty_files":[],"command_class_cache":{},"risk_score":0,"last_drain_seq":0}
JSON
}

# --- Lock helpers ---
# Use a single lock fd 9. macOS has flock via util-linux (Homebrew); if absent,
# fall back to mkdir-based mutex (the same posture Area B X3.B.1+B.2 used).
acquire_state_lock() {
  local mode="${1:-x}"
  _state_machine_ensure_dir
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE_LOCK"
    case "$mode" in
      s) flock -s 9 ;;
      *) flock -x 9 ;;
    esac
    REIN_STATE_LOCK_BACKEND="flock"
    return 0
  fi
  # Fallback: mkdir-based mutex. Treat both s/x as exclusive (no shared mode);
  # this is safe but loses parallel-reader scalability — acceptable for hooks.
  # Tighter polling (10ms) + longer timeout (default 10000ms) handles high-
  # contention bursts like 100x concurrent append_journal — codex Round 1 T4 fix.
  # REIN_STATE_LOCK_TIMEOUT_MS overrides the ceiling (tests force fast failure).
  local timeout_ms="${REIN_STATE_LOCK_TIMEOUT_MS:-10000}"
  local waited_ms=0
  while ! mkdir "$STATE_LOCK.d" 2>/dev/null; do
    [ "$waited_ms" -ge "$timeout_ms" ] && {
      echo "[rein] state-machine: lock contended >${timeout_ms}ms ($STATE_LOCK.d). Stale lock — rmdir manually if no hook running." >&2
      return 2
    }
    sleep 0.01
    waited_ms=$((waited_ms + 10))
  done
  REIN_STATE_LOCK_BACKEND="mkdir"
  return 0
}

release_state_lock() {
  case "${REIN_STATE_LOCK_BACKEND:-}" in
    flock)
      exec 9>&-
      ;;
    mkdir)
      rmdir "$STATE_LOCK.d" 2>/dev/null || true
      ;;
  esac
  REIN_STATE_LOCK_BACKEND=""
}

# --- read_state: parse → echo. On absent/malformed → echo default + stderr NOTICE. ---
read_state() {
  _state_machine_paths
  local py
  if ! py=$(_state_machine_python); then
    _state_machine_default_state
    echo "[rein] state-machine: python missing — using default state (legacy fallback)." >&2
    return 0
  fi
  if [ ! -f "$STATE_FILE" ]; then
    _state_machine_default_state
    return 0
  fi
  local out
  if out=$("$py" - "$STATE_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        sys.exit(2)
    sv = data.get("schema_version")
    if sv != 1:
        sys.exit(3)
    # Re-emit canonical (preserve unknown keys for forward compat).
    print(json.dumps(data, separators=(",", ":"), sort_keys=True))
except Exception:
    sys.exit(2)
PY
); then
    printf '%s\n' "$out"
    return 0
  fi
  local rc=$?
  case "$rc" in
    3)
      echo "[rein] state-machine: unrecognised schema_version in $STATE_FILE — using default (legacy fallback)." >&2
      ;;
    *)
      echo "[rein] state-machine: malformed JSON in $STATE_FILE — using default (legacy fallback)." >&2
      ;;
  esac
  _state_machine_default_state
}

# --- state_is_valid: 0 iff STATE_FILE exists, parses as a JSON object with
#     schema_version == 1, AND every field the fast-path mode derivation depends
#     on is well-typed (mode str, last_drain_seq int, dirty_files list). Lets
#     fast-path callers tell a state that genuinely reports mode=answer apart
#     from the default "answer" that read_state / read_effective_mode fall back
#     to on any read or parse failure. Malformed JSON, unknown schema, OR a
#     schema-v1 file with a corrupt field must all fall through to legacy
#     behaviour (design memo §2.3 / §8.4 legacy-fallback contract), not be
#     trusted as a real mode. Silent predicate — the user-facing NOTICE is
#     emitted by read_state on the dispatcher drain path. Iterations: file
#     existence alone (codex Round 2 HIGH), schema-only (codex Round 4 HIGH). ---
state_is_valid() {
  _state_machine_paths
  [ -f "$STATE_FILE" ] || return 1
  local py
  py=$(_state_machine_python) || return 1
  "$py" - "$STATE_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)

def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)

# Validate the design memo §2 schema-v1 contract: the fast-path trusts a state's
# mode only when the file is a complete, well-typed schema-v1 document. Tightened
# across review rounds — R2 schema_version, R4 field types, R5 mode enum,
# R6 required-field presence — converging on the exact §2 required/optional split.
# mode is an exact enum (§3); this also rejects whitespace values like
# "answer bogus" that read_effective_mode's word-split `read mode ...` would
# reduce to a trusted "answer".
valid_modes = ("answer", "explore", "source_edit", "commit")
required_ok = (
    data.get("schema_version") == 1
    and data.get("mode") in valid_modes
    and isinstance(data.get("updated_at"), str)
    and isinstance(data.get("dirty_files"), list)
    and is_int(data.get("last_drain_seq"))
)
# Optional fields (design §2): type-check only when present.
optional_ok = (
    ("command_class_cache" not in data or isinstance(data["command_class_cache"], dict))
    and ("risk_score" not in data or is_int(data["risk_score"]))
)
sys.exit(0 if required_ok and optional_ok else 1)
PY
}

# --- write_state <json>: atomic rename. Returns 0 on success, 2 on failure. ---
# codex Round 1 HIGH fix: $$ is shared across bash subshell children in concurrent
# write scenarios, leading to .tmp path collisions. Use mktemp for per-write
# uniqueness on same filesystem (template forces same dir → mv is atomic rename).
write_state() {
  local json="$1"
  _state_machine_ensure_dir
  local tmp
  tmp=$(mktemp "$STATE_FILE.tmp.XXXXXX" 2>/dev/null)
  if [ -z "$tmp" ]; then
    echo "[rein] state-machine: mktemp failed for state.json.tmp ($STATE_FILE)" >&2
    return 2
  fi
  if ! printf '%s\n' "$json" >"$tmp" 2>/dev/null; then
    echo "[rein] state-machine: failed to write state.json.tmp ($tmp)" >&2
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  if ! mv -f "$tmp" "$STATE_FILE" 2>/dev/null; then
    echo "[rein] state-machine: atomic rename of state.json failed ($STATE_FILE)" >&2
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  return 0
}

# --- seq allocation (memo §4.2, codex Round 5 fix): max of last_drain_seq +
#     active journals max + .processing journals max + 1. ---
_state_machine_max_seq_in_file() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return 0; }
  # Extract first column (tab-separated). Strip non-numeric. Find max.
  awk -F '\t' '
    BEGIN { m = 0 }
    {
      v = $1
      if (v ~ /^[0-9]+$/ && (v + 0) > m) m = v + 0
    }
    END { print m }
  ' "$f" 2>/dev/null || echo 0
}

_state_machine_next_seq() {
  _state_machine_paths
  local state_seq=0
  local py
  if py=$(_state_machine_python) && [ -f "$STATE_FILE" ]; then
    state_seq=$("$py" - "$STATE_FILE" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get("last_drain_seq", 0)
    print(int(v) if isinstance(v, int) and v >= 0 else 0)
except Exception:
    print(0)
PY
)
    [ -z "$state_seq" ] && state_seq=0
  fi
  local max_v=$state_seq
  local f m
  for f in "$J_EDITS" "$J_BASH" "$J_STOP" \
           "$J_EDITS.processing" "$J_BASH.processing" "$J_STOP.processing"; do
    m=$(_state_machine_max_seq_in_file "$f")
    [ "$m" -gt "$max_v" ] && max_v=$m
  done
  echo $((max_v + 1))
}

# --- append_journal <kind> <payload-fields-tab-separated> ---
# kind ∈ {edits, bash, stop}. payload is appended after seq + iso-ts columns.
# Caller is responsible for holding the lock during the call when serialization
# across hooks is required; this function acquires its own lock when caller has
# not (REIN_STATE_LOCK_BACKEND check).
append_journal() {
  local kind="$1"
  local payload="$2"
  _state_machine_paths
  local target
  case "$kind" in
    edits) target="$J_EDITS" ;;
    bash)  target="$J_BASH" ;;
    stop)  target="$J_STOP" ;;
    *)
      echo "[rein] state-machine: unknown journal kind '$kind' (expected edits|bash|stop)" >&2
      return 2
      ;;
  esac
  local owned_lock=0
  if [ -z "${REIN_STATE_LOCK_BACKEND:-}" ]; then
    acquire_state_lock x || return 2
    owned_lock=1
  fi
  local seq ts rc
  seq=$(_state_machine_next_seq)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _state_machine_ensure_dir
  printf '%s\t%s\t%s\n' "$seq" "$ts" "$payload" >>"$target"
  rc=$?
  [ "$owned_lock" = 1 ] && release_state_lock
  if [ "$rc" -ne 0 ]; then
    echo "[rein] state-machine: append_journal write failed (kind=$kind target=$target)" >&2
    return 2
  fi
  return 0
}

# --- drain_state: dispatcher 9-step drain (design memo §4.3) ---
#
# Atomically:
#   1. acquire lock (if caller hasn't already)
#   2. read state.json
#   3. for each journal: mv active → .processing (merge stale .processing if present)
#   4. union all .processing entries, sort by numeric seq, filter > last_drain_seq
#   5. apply transitions: edit → mode=source_edit + dirty append;
#                         bash-result commit/exit=0 → mode=answer + dirty=[];
#                         bash-result commit/exit!=0 → mode=source_edit (dirty 보존);
#                         bash-result test → mode=source_edit (dirty 보존);
#                         turn-end → mode=answer (dirty 보존)
#   6. update last_drain_seq to max seq applied
#   7. write state.json (atomic)
#   8. on success only, rm .processing files
#   9. release lock
#
# Returns 0 on success (incl. nothing-to-drain), 2 on infra failure (write fails,
# python missing, etc.). On rc=2, .processing files retained → next drain retry.
drain_state() {
  _state_machine_paths
  local owned_lock=0
  if [ -z "${REIN_STATE_LOCK_BACKEND:-}" ]; then
    acquire_state_lock x || return 2
    owned_lock=1
  fi

  local py
  if ! py=$(_state_machine_python); then
    [ "$owned_lock" = 1 ] && release_state_lock
    return 2
  fi

  # Optional current Bash classification (design memo §4.3 step 6).
  # Caller (pre-bash-dispatcher.sh) passes the in-flight command class so the
  # state reflects mode for the ABOUT-TO-EXECUTE bash (e.g., flush_plan_coverage
  # needs to see mode=commit when `git commit` is dispatched). Codex Round 1
  # X4.C.2 HIGH fix.
  local current_class="${1:-}"

  local cur_state
  cur_state=$(read_state)

  # Step 3: stage each active journal into its .processing companion. Merge
  # stale .processing entries with fresh active (codex Round 2 stale+fresh
  # pattern, Area B X3.B.2 차용). codex Round 1 X4.C.2 Medium fix: rm active
  # ONLY when cat into .processing succeeded (cat failure → leave active
  # intact for next drain retry, loss zero).
  local kind active proc
  for kind in edits bash stop; do
    case "$kind" in
      edits) active="$J_EDITS"; proc="$J_EDITS.processing" ;;
      bash)  active="$J_BASH";  proc="$J_BASH.processing"  ;;
      stop)  active="$J_STOP";  proc="$J_STOP.processing"  ;;
    esac
    if [ -f "$active" ]; then
      if [ -f "$proc" ]; then
        if cat "$active" >> "$proc" 2>/dev/null; then
          rm -f "$active" 2>/dev/null
        fi
      else
        mv -f "$active" "$proc" 2>/dev/null
      fi
    fi
  done

  # Step 4 + 5 + 6: apply pending journal transitions, then current Bash class.
  local new_state
  new_state=$("$py" - "$cur_state" "$STATE_DIR" "$current_class" <<'PY' 2>/dev/null
import json, sys, os
state_in = sys.argv[1]
state_dir = sys.argv[2]
current_class = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    state = json.loads(state_in)
except Exception:
    state = {}
mode = state.get("mode", "answer")
dirty = state.get("dirty_files", [])
lds = int(state.get("last_drain_seq", 0))

entries = []
for fname in (
    "state-pending-edits.log.processing",
    "state-pending-bash.log.processing",
    "state-pending-stop.log.processing",
):
    p = os.path.join(state_dir, fname)
    if not os.path.isfile(p):
        continue
    try:
        with open(p) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 3:
                    continue
                try:
                    seq = int(parts[0])
                except Exception:
                    continue
                if seq <= lds:
                    continue
                entries.append((seq, parts))
    except OSError:
        pass

entries.sort(key=lambda x: x[0])

dirty_paths = {d.get("path"): d for d in dirty if isinstance(d, dict)}

for seq, parts in entries:
    kind = parts[2] if len(parts) > 2 else ""
    if kind == "edit" and len(parts) >= 5:
        path = parts[3]
        file_kind = parts[4]
        if path not in dirty_paths:
            dirty_paths[path] = {"path": path, "kind": file_kind}
        mode = "source_edit"
    elif kind == "bash-result" and len(parts) >= 5:
        rc = parts[3]
        cls = parts[4]
        if cls == "commit":
            if rc == "0":
                mode = "answer"
                dirty_paths.clear()
            else:
                mode = "source_edit"
        elif cls == "test":
            mode = "source_edit"
        # safe / dangerous / long-running: mode unchanged
    elif kind == "turn-end":
        mode = "answer"
    if seq > lds:
        lds = seq

# Step 6: apply CURRENT bash classification (about-to-execute, no journal entry).
# Design memo §3.2: source_edit + commit/test class Bash → mode=commit.
# answer + safe class → explore. Other transitions follow §3.2 table.
if current_class:
    if current_class == "commit" or current_class == "test":
        mode = "commit"
    elif current_class == "safe" or current_class == "explore-read":
        if mode == "answer":
            mode = "explore"
    # dangerous / long-running: no mode change

state["mode"] = mode
state["dirty_files"] = list(dirty_paths.values())
state["last_drain_seq"] = lds
state["schema_version"] = 1
import datetime
state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps(state, separators=(",", ":"), sort_keys=True))
PY
)

  local py_rc=$?
  if [ "$py_rc" -ne 0 ] || [ -z "$new_state" ]; then
    [ "$owned_lock" = 1 ] && release_state_lock
    return 2
  fi

  # Step 7: write atomic
  if ! write_state "$new_state"; then
    [ "$owned_lock" = 1 ] && release_state_lock
    return 2
  fi

  # Step 8: remove .processing only on successful write
  rm -f "$J_EDITS.processing" "$J_BASH.processing" "$J_STOP.processing" 2>/dev/null

  [ "$owned_lock" = 1 ] && release_state_lock
  return 0
}

# --- read_effective_mode: state.mode + all pending journal entries (incl .processing) ---
# Reader holds the lock so it observes a consistent snapshot (memo §3.3).
read_effective_mode() {
  _state_machine_paths
  local owned_lock=0
  if [ -z "${REIN_STATE_LOCK_BACKEND:-}" ]; then
    acquire_state_lock s || { echo "answer"; return 2; }
    owned_lock=1
  fi
  local state_json mode last_drain_seq
  state_json=$(read_state)
  local py
  py=$(_state_machine_python) || { echo "answer"; [ "$owned_lock" = 1 ] && release_state_lock; return 0; }
  # X4.C.3 fix — pipe (`printf | python`) + heredoc 동시 redirect 시 bash 는
  # heredoc 을 stdin 으로 우선 적용하므로 `sys.stdin.read()` 가 state_json 대신
  # heredoc 본문 (= python code) 을 읽어 JSON parse 실패 → 항상 "answer" fallback.
  # state_json 을 argv 로 전달하면 stdin 충돌 회피.
  read mode last_drain_seq < <(
    "$py" - "$state_json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("mode", "answer"), int(d.get("last_drain_seq", 0)))
except Exception:
    print("answer", 0)
PY
  )
  [ -z "$mode" ] && mode="answer"
  [ -z "$last_drain_seq" ] && last_drain_seq=0
  # Apply pending journal entries (edits / bash / stop). Memo §3.3: sorted by seq.
  # codex Round 1 HIGH fix: concatenating files in fixed order then applying does
  # NOT yield seq ordering. e.g. stop(seq=1) + edit(seq=2) must end as source_edit,
  # not answer. Sort all entries by numeric seq FIRST, then apply transitions.
  local applied
  applied=$(
    {
      for f in "$J_EDITS" "$J_BASH" "$J_STOP" \
               "$J_EDITS.processing" "$J_BASH.processing" "$J_STOP.processing"; do
        [ -f "$f" ] && cat "$f"
      done
    } 2>/dev/null \
      | awk -F '\t' '$1 ~ /^[0-9]+$/' \
      | sort -t $'\t' -k1,1n \
      | awk -F '\t' -v lds="$last_drain_seq" -v init="$mode" '
          function set_mode(m) { cur = m }
          BEGIN { cur = init }
          ($1 + 0) > (lds + 0) {
            kind = $3
            if (kind == "edit") {
              set_mode("source_edit")
            } else if (kind == "bash-result") {
              # $4=exit, $5=class
              if ($5 == "commit") {
                if ($4 == "0") set_mode("answer")
                else set_mode("source_edit")
              } else if ($5 == "test") {
                set_mode("source_edit")
              }
            } else if (kind == "turn-end") {
              set_mode("answer")
            }
          }
          END { print cur }
        '
  )
  [ -z "$applied" ] && applied="$mode"
  printf '%s\n' "$applied"
  [ "$owned_lock" = 1 ] && release_state_lock
  return 0
}

# --- read_fast_path_state [match_path]: atomic combined fast-path query ---
# Cycle X4.C.5 (design memo §9 Q-5, spike §5). Folds the three reads that
# X4.C.3's fast-path performed across separate python invocations —
# state_is_valid (validate), read_effective_mode (mode), and the M1 dirty
# match — into ONE python process under ONE shared lock. The cold-start of
# each extra `python3` (~25ms) was what tipped the fast-path into a net
# latency regression (spike §3); collapsing 3-5 invocations to 1 removes that
# tax while preserving the exact decisions of the legacy callers.
#
# Read-only: state.json is never mutated (single-writer = dispatcher, memo §4.1).
# A shared lock is held for the whole snapshot so the validate + mode +
# dirty-match observe one consistent view (same posture as read_effective_mode).
#
# Output: one tab-separated line "<valid>\t<mode>\t<dirty_match>" where
#   valid       = "1" iff the file is a complete well-typed schema-v1 document
#                 (mirrors state_is_valid). "0" otherwise.
#   mode        = effective mode = state.mode merged with seq-ordered pending
#                 journal entries (mirrors read_effective_mode). "answer" when
#                 valid="0" so callers gating on `valid="1"` never act on it.
#   dirty_match = "1" iff match_path is present in the ON-DISK state.dirty_files
#                 (mirrors the M1 read_state-based match, NOT journal-merged).
#                 "0" when no match_path arg is given or no entry matches.
#
# Fallback contract (memo §2.3 / §8.4) — two tiers, BOTH safe because every
# caller acts only on valid="1":
#   - python-missing OR lock-acquire failure → return NON-ZERO (1 / 2) plus a
#     safe "0\tanswer\t0" line. The query could not run at all (execution error).
#   - absent / malformed / unknown-schema / parse-error state → return 0 with
#     valid="0". The query ran and authoritatively reports "no trustworthy
#     state" — this mirrors state_is_valid returning false (a normal answer),
#     not a hard error, so rc stays 0 and the verdict rides in the valid field.
# Either tier makes valid-gated callers fall through to the legacy path, exactly
# as a failed state_is_valid / read_effective_mode did before.
read_fast_path_state() {
  _state_machine_paths
  local match_path="${1:-}"
  local py
  if ! py=$(_state_machine_python); then
    printf '%s\t%s\t%s\n' "0" "answer" "0"
    return 1
  fi
  local owned_lock=0
  if [ -z "${REIN_STATE_LOCK_BACKEND:-}" ]; then
    acquire_state_lock s || { printf '%s\t%s\t%s\n' "0" "answer" "0"; return 2; }
    owned_lock=1
  fi
  local out rc
  out=$("$py" - "$STATE_FILE" "$STATE_DIR" "$match_path" <<'PY' 2>/dev/null
import json, os, sys

state_file = sys.argv[1]
state_dir = sys.argv[2]
match_path = sys.argv[3] if len(sys.argv) > 3 else ""

def emit(valid, mode, dirty):
    sys.stdout.write("%s\t%s\t%s\n" % (valid, mode, dirty))

def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)

# --- Step 1: validate (mirror of state_is_valid). The fast-path trusts a
# state's mode only when the file is a complete, well-typed schema-v1 document
# (design memo §2). Anything short of that → not-valid → legacy fallback. ---
if not os.path.isfile(state_file):
    emit("0", "answer", "0"); sys.exit(0)
try:
    with open(state_file) as f:
        data = json.load(f)
except Exception:
    emit("0", "answer", "0"); sys.exit(0)
if not isinstance(data, dict):
    emit("0", "answer", "0"); sys.exit(0)

valid_modes = ("answer", "explore", "source_edit", "commit")
required_ok = (
    data.get("schema_version") == 1
    and data.get("mode") in valid_modes
    and isinstance(data.get("updated_at"), str)
    and isinstance(data.get("dirty_files"), list)
    and is_int(data.get("last_drain_seq"))
)
optional_ok = (
    ("command_class_cache" not in data or isinstance(data["command_class_cache"], dict))
    and ("risk_score" not in data or is_int(data["risk_score"]))
)
if not (required_ok and optional_ok):
    emit("0", "answer", "0"); sys.exit(0)

# --- Step 2: effective mode (mirror of read_effective_mode). state.mode merged
# with all pending journal entries (active + .processing), applied in strict
# numeric-seq order, skipping entries already drained (seq <= last_drain_seq).
# Same transition table as read_effective_mode's awk + drain_state's python. ---
mode = data.get("mode", "answer")
lds = int(data.get("last_drain_seq", 0))

entries = []
for fname in (
    "state-pending-edits.log",
    "state-pending-bash.log",
    "state-pending-stop.log",
    "state-pending-edits.log.processing",
    "state-pending-bash.log.processing",
    "state-pending-stop.log.processing",
):
    p = os.path.join(state_dir, fname)
    if not os.path.isfile(p):
        continue
    try:
        with open(p) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 3:
                    continue
                try:
                    seq = int(parts[0])
                except Exception:
                    continue
                entries.append((seq, parts))
    except OSError:
        pass

entries.sort(key=lambda x: x[0])
for seq, parts in entries:
    if seq <= lds:
        continue
    kind = parts[2]
    if kind == "edit":
        mode = "source_edit"
    elif kind == "bash-result" and len(parts) >= 5:
        exit_code = parts[3]
        cls = parts[4]
        if cls == "commit":
            mode = "answer" if exit_code == "0" else "source_edit"
        elif cls == "test":
            mode = "source_edit"
    elif kind == "turn-end":
        mode = "answer"

# --- Step 3: dirty match (mirror of M1's read_state-based match). The match is
# against the ON-DISK state.dirty_files snapshot — NOT the journal-merged set —
# to stay byte-for-byte equivalent with the legacy M1 read_state path. ---
dirty = "0"
if match_path:
    for d in data.get("dirty_files", []) or []:
        if isinstance(d, dict) and d.get("path") == match_path:
            dirty = "1"
            break

emit("1", mode, dirty)
PY
)
  rc=$?
  [ "$owned_lock" = 1 ] && release_state_lock
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\t%s\t%s\n' "0" "answer" "0"
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}
