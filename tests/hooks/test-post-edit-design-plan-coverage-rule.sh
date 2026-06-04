#!/usr/bin/env bash
# tests/hooks/test-post-edit-design-plan-coverage-rule.sh
#
# Verifies the plugin PostToolUse sub-hook
# `plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh`:
#
#   (a) Match cases emit a PostToolUse envelope whose additionalContext
#       contains the design-plan-coverage 행동 강령.
#         - docs/specs/** (relative)
#         - docs/plans/** (absolute)
#         - trail/dod/dod-*.md
#   (b) Path resolution fallback chain works:
#         tool_input.file_path → tool_response.filePath → tool_result.file_path
#   (c) Non-matching paths produce *no* stdout (silent — won't inflate context).
#   (d) Malformed JSON exits silently with no stdout (post-hook contract).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

HOOK="$PROJECT_DIR/plugins/rein-core/hooks/post-edit-design-plan-coverage-rule.sh"
PLUGIN_ROOT="$PROJECT_DIR/plugins/rein-core"

[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing" >&2; exit 1; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable" >&2; exit 1; }

OUT="$(mktemp)"
# ROUTE-BIND-1: stderr 캡처용 — nudge advisory 는 stderr(>&2) 로만 나가므로
# stdout(OUT) envelope 검증과 독립. invoke_err 가 여기에 쓴다.
ERR="$(mktemp)"
# X4.C.3: the hook fast-path-skips its envelope when the resolved project's
# .rein/state.json reports mode=answer. Pin an isolated (state-absent) project
# dir so these envelope-contract assertions exercise the legacy path
# deterministically instead of inheriting the maintainer repo's live state.json.
# ROUTE-BIND-1: the same SANDBOX doubles as the resolved PROJECT_DIR for both
# the claim helper (writer) and the host hook (reader) — REIN_PROJECT_DIR_OVERRIDE
# pins both to it, so claim create/consume happens inside the sandbox (no
# maintainer repo .rein/cache pollution). `mkdir -p "$SANDBOX/trail"` so the
# helper's resolve_project_dir does not climb past the sandbox.
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/trail"
export REIN_PROJECT_DIR_OVERRIDE="$SANDBOX"
trap 'rm -rf "$OUT" "$ERR" "$SANDBOX"' EXIT

invoke() {
  local input="$1"
  : > "$OUT"
  printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
}

# ROUTE-BIND-1 helpers ------------------------------------------------------
# make_claim: 에이전트(spec-writer/plan-writer) 의 작성-직전 claim 을 시뮬레이션.
make_claim() {
  bash "$PROJECT_DIR/plugins/rein-core/scripts/rein-mark-design-provenance.sh" "$1" "$2" sess
}
# invoke_err: stdout(OUT) + stderr(ERR) 를 둘 다 캡처하는 호스트 훅 호출.
invoke_err() {
  : >"$OUT"; : >"$ERR"
  printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>"$ERR" || true
}
# abs_of / hash_of / marker_of: 호스트 훅·helper 와 동일한 hash 규약으로 claim
# 마커 경로를 재구성 (sandbox 안 .rein/cache/.design-provenance/<hash>.touched).
abs_of() { python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$1"; }
hash_of() { printf '%s' "$(abs_of "$1")" | shasum | cut -c1-16; }
marker_of() { echo "$SANDBOX/.rein/cache/.design-provenance/$(hash_of "$1").touched"; }

assert_envelope() {
  local label="$1"
  python3 - "$OUT" <<'PY' || { echo "FAIL: $label — envelope assertion" >&2; cat "$OUT" >&2; exit 1; }
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
assert raw.strip(), "empty stdout"
data = json.loads(raw)
hso = data.get("hookSpecificOutput", {})
assert hso.get("hookEventName") == "PostToolUse", f"hookEventName={hso.get('hookEventName')!r}"
ctx = hso.get("additionalContext", "")
assert "행동 강령" in ctx, "missing 행동 강령 in additionalContext"
PY
  echo "  ok: $label"
}

assert_silent() {
  local label="$1"
  if [ -s "$OUT" ]; then
    echo "FAIL: $label — expected no stdout, got:" >&2
    cat "$OUT" >&2
    exit 1
  fi
  echo "  ok: $label"
}

# (a1) docs/specs match (relative path)
invoke '{"tool_input":{"file_path":"docs/specs/2026-01-01-foo.md"}}'
assert_envelope "docs/specs relative match"

# (a2) docs/plans match (absolute path)
invoke '{"tool_input":{"file_path":"/Users/foo/repo/docs/plans/2026-01-01-bar.md"}}'
assert_envelope "docs/plans absolute match"

# (a3) trail/dod/dod-*.md match
invoke '{"tool_input":{"file_path":"trail/dod/dod-2026-05-12-test.md"}}'
assert_envelope "trail/dod/dod-*.md match"

# (b1) fallback: tool_response.filePath (when tool_input.file_path absent)
invoke '{"tool_response":{"filePath":"docs/specs/foo.md"}}'
assert_envelope "tool_response.filePath fallback"

# (b2) legacy fallback: tool_result.file_path
invoke '{"tool_result":{"file_path":"docs/plans/foo.md"}}'
assert_envelope "tool_result.file_path legacy fallback"

# (c1) non-matching path (src file) — silent
invoke '{"tool_input":{"file_path":"src/foo.py"}}'
assert_silent "src/foo.py non-match → silent"

# (c2) non-matching path: trail/dod/ but no dod- prefix → silent
invoke '{"tool_input":{"file_path":"trail/dod/notes.md"}}'
assert_silent "trail/dod/notes.md (no dod- prefix) → silent"

# (c3) non-matching path: docs/other/ → silent
invoke '{"tool_input":{"file_path":"docs/other/x.md"}}'
assert_silent "docs/other/x.md → silent"

# (d) malformed JSON → silent
invoke 'not json at all'
assert_silent "malformed JSON → silent"

# (e) empty stdin → silent
: > "$OUT"
printf '' | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "empty stdin → silent"

# (f) CLAUDE_PLUGIN_ROOT unset → silent (scaffold mode)
: > "$OUT"
printf '%s' '{"tool_input":{"file_path":"docs/specs/foo.md"}}' \
  | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" >"$OUT" 2>/dev/null || true
assert_silent "CLAUDE_PLUGIN_ROOT unset → silent"

# ---------------------------------------------------------------------------
# ROUTE-BIND-1 nudge / consume regression (SC-10 (a)~(g) + codex R3 (c'))
# nudge 는 stderr advisory(exit 0) — 위의 stdout envelope 케이스와 독립.
# 매칭 키 = .rein/cache/.design-provenance/<hash(ABS)>.touched 의 path= 대조.
# ---------------------------------------------------------------------------

# (a) claim 존재 → 무발화 + claim 소비됨
P="docs/specs/2026-01-01-a.md"; make_claim "$P" spec-writer
[ -f "$(marker_of "$P")" ] || { echo "FAIL (a): claim not created by helper" >&2; exit 1; }
invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"
grep -qi "직접 작성" "$ERR" && { echo "FAIL (a): nudge emitted with claim present" >&2; cat "$ERR" >&2; exit 1; }
[ -f "$(marker_of "$P")" ] && { echo "FAIL (a): claim not consumed" >&2; exit 1; }
echo "  ok: (a) claim → no nudge + consumed"

# (b) claim 부재 → nudge
P="docs/plans/2026-01-01-b.md"
invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"
grep -qi "직접 작성" "$ERR" || { echo "FAIL (b): no nudge without claim" >&2; cat "$ERR" >&2; exit 1; }
echo "  ok: (b) no claim → nudge"

# (c) claim 소비 후 동일 경로 재편집(claim 미재기록) → nudge — consume 1회성
P="docs/specs/2026-01-01-c.md"; make_claim "$P" spec-writer
invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"   # 1회차: 소비, 무발화
grep -qi "직접 작성" "$ERR" && { echo "FAIL (c1): nudge on first claimed write" >&2; exit 1; }
invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"   # 2회차: claim 부재 → nudge
grep -qi "직접 작성" "$ERR" || { echo "FAIL (c2): no nudge on second write (consume not one-shot)" >&2; exit 1; }
echo "  ok: (c) consume one-shot — second write nudges"

# (c') codex R3 — 동일파일 반복편집 정상 경로 (매 write 직전 재-claim) → 무발화 유지
P="docs/plans/2026-01-01-selffix.md"
for i in 1 2 3; do
  make_claim "$P" plan-writer          # 매 authored write 직전 재-claim (SC-2/§4.3 불변식)
  invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"
  grep -qi "직접 작성" "$ERR" && { echo "FAIL (c'): nudge on re-claimed self-fix write #$i" >&2; exit 1; }
done
echo "  ok: (c') same-file repeated edits with pre-write re-claim → no nudge"

# (d) 비-design 경로 → nudge 코드 미도달 (NFR-1 과 공유)
invoke_err '{"tool_input":{"file_path":"src/foo.py"}}'
grep -qi "직접 작성" "$ERR" && { echo "FAIL (d): nudge on non-design path" >&2; exit 1; }
echo "  ok: (d) non-design → no nudge (NFR-1)"

# (e) hash 동일하나 path= 불일치 → nudge (정확 대조 grep -qxF)
P="docs/specs/2026-01-01-e.md"
M="$(marker_of "$P")"; mkdir -p "$(dirname "$M")"
printf 'path=/some/other/path.md\nagent=spec-writer\nsession=sess\ncreated=2026-01-01T00:00:00\n' > "$M"
invoke_err "{\"tool_input\":{\"file_path\":\"$P\"}}"
grep -qi "직접 작성" "$ERR" || { echo "FAIL (e): path= mismatch should nudge" >&2; exit 1; }
echo "  ok: (e) hash-collision path= mismatch → nudge"

# (f) CLAUDE_PLUGIN_ROOT 미설정 → silent exit (기존 가드 보존)
: >"$ERR"
printf '%s' '{"tool_input":{"file_path":"docs/specs/2026-01-01-f.md"}}' \
  | env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" >/dev/null 2>"$ERR" || true
grep -qi "직접 작성" "$ERR" && { echo "FAIL (f): nudge without CLAUDE_PLUGIN_ROOT" >&2; exit 1; }
echo "  ok: (f) CLAUDE_PLUGIN_ROOT unset → silent"

# (g) claim 존재하나 rm 실패(권한) → exit 0 유지(비차단 불변식)
# root 권한이면 chmod a-w 가 무력화될 수 있음 — 그 경우 skip + 사유 로그.
P="docs/specs/2026-01-01-g.md"; make_claim "$P" spec-writer
G_DIR="$(dirname "$(marker_of "$P")")"
chmod a-w "$G_DIR" 2>/dev/null || true
# rm-failure 가 실제로 강제됐는지 확인 (root 면 디렉토리가 여전히 쓰기 가능).
if [ -w "$G_DIR" ]; then
  chmod u+w "$G_DIR" 2>/dev/null || true
  echo "  skip: (g) rm-failure path — directory still writable (likely root); non-blocking invariant covered by code review (|| true guard)"
else
  : >"$ERR"
  printf '%s' "{\"tool_input\":{\"file_path\":\"$P\"}}" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >/dev/null 2>"$ERR"; RC=$?
  chmod u+w "$G_DIR" 2>/dev/null || true   # 복구 (trap cleanup 위해)
  # 불변식 = "never exit 2 OR exit 1" → exit 0 을 정확히 요구 (RC!=2 보다 엄격).
  [ "$RC" -eq 0 ] || { echo "FAIL (g): hook exited $RC on rm failure (must be 0 — never exit 1 or 2)" >&2; exit 1; }
  echo "  ok: (g) rm failure → exit 0 (non-blocking)"
fi

# (h) hash 명령 실패(shasum/sha1sum 둘 다 깨짐) → fail-soft (exit 0 + nudge)
# claim 이 존재해도 hash 실패로 매칭 불가 → nudge 발화, 비차단. set -e 아래
# _hash=$(...) || _hash="" 가드의 회귀 (codex R1 — 무가드 hash 가 set -e 로 비정상
# 종료하던 결함). PATH 에 실패 stub 을 prepend 해 hash 파이프(pipefail)를 깨뜨린다.
P="docs/specs/2026-01-01-h.md"; make_claim "$P" spec-writer
HBIN="$SANDBOX/hashfail-bin"; mkdir -p "$HBIN"
printf '#!/bin/sh\nexit 1\n' > "$HBIN/shasum";  chmod +x "$HBIN/shasum"
printf '#!/bin/sh\nexit 1\n' > "$HBIN/sha1sum"; chmod +x "$HBIN/sha1sum"
: >"$ERR"
printf '%s' "{\"tool_input\":{\"file_path\":\"$P\"}}" \
  | PATH="$HBIN:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK" >/dev/null 2>"$ERR"; RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL (h): hook exited $RC on hash failure (must be 0, non-blocking)" >&2; exit 1; }
grep -qi "직접 작성" "$ERR" || { echo "FAIL (h): hash failure should fall through to nudge" >&2; exit 1; }
echo "  ok: (h) hash-command failure → exit 0 + nudge (fail-soft)"

echo "test-post-edit-design-plan-coverage-rule: OK"
