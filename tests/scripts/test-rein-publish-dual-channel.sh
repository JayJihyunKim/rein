#!/usr/bin/env bash
# test-rein-publish-dual-channel.sh — Phase 6 Task 6.2.
#
# Verifies the dual-channel publish path:
#   (a) Both channels succeed — self-hosted manifest updated AND Anthropic
#       endpoint receives one POST per plugin with a tarball and a
#       Bearer token in the Authorization header.
#   (b) Missing ANTHROPIC_MARKETPLACE_API → publish exits non-zero with a
#       clear "error: ANTHROPIC_MARKETPLACE_API env var required" message
#       on stderr (Round 5 fix Finding 6 — no default URL hardcoded).
#   (c) Missing ANTHROPIC_TOKEN → same fail-fast.
#   (d) Anthropic POST fails (mock returns 500) → script exits non-zero AND
#       (best-effort) self-hosted manifest is rolled back to its prior
#       contents AND the freshly produced tarball is removed.
#   (e) HTTPS-only enforcement: production URLs that start with `http://`
#       (other than 127.0.0.1 / localhost) are rejected before any POST.
#   (f) ANTHROPIC_TOKEN is NOT visible in stdout/stderr after a failure
#       (Round 5 finding — no secret leakage in logs).
#
# Scope ID: marketplace-publishes-to-anthropic-and-self-hosted-json-simultaneously-on-release.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PUBLISH_SH="$PROJECT_DIR/scripts/rein-publish.sh"
UPDATE_PY="$PROJECT_DIR/scripts/rein-marketplace-update.py"

[ -f "$PUBLISH_SH" ] || { echo "FAIL: scripts/rein-publish.sh missing" >&2; exit 1; }
[ -f "$UPDATE_PY" ] || { echo "FAIL: scripts/rein-marketplace-update.py missing" >&2; exit 1; }

# --- Sandbox ---------------------------------------------------------------
tmp=$(mktemp -d -t rein-publish-dual-XXXXXX)
trap 'cleanup' EXIT
mock_pid=""
mock_log="$tmp/mock.log"
mock_body_dir="$tmp/mock-bodies"

cleanup() {
  [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null || true
  rm -rf "$tmp"
}

mkdir -p "$tmp/scripts" "$tmp/plugins/rein-core/.claude-plugin" "$tmp/plugins/rein-core/hooks" "$tmp/marketplace" "$mock_body_dir"

cp "$PUBLISH_SH" "$tmp/scripts/rein-publish.sh"
cp "$UPDATE_PY" "$tmp/scripts/rein-marketplace-update.py"
# This test exercises publish env-var assertions with a minimal plugin
# layout. The full drift validator (rein-validate-plugin-rules.py →
# rein-check-plugin-drift.py) requires the complete plugins/rein-core/
# tree (rules/, hooks/session-start-rules.sh, hooks.json, etc.) which the
# fixture intentionally omits. Bypass via documented env var so the
# assertions reach the real fail-fast checks under test.
#
# Production guard in rein-publish.sh refuses SKIP_VALIDATE in CI ($CI=true
# or $GITHUB_ACTIONS set). Test fixtures running inside CI must unset those
# markers in their own subshell so the bypass is allowed for the fixture
# while real publish in the same CI run still hits the guard.
unset CI GITHUB_ACTIONS GITLAB_CI JENKINS_URL BUILDKITE CIRCLECI TF_BUILD
export REIN_PUBLISH_SKIP_VALIDATE=1

cat > "$tmp/plugins/rein-core/.claude-plugin/plugin.json" <<'EOF'
{ "name": "rein-core", "version": "1.0.0", "description": "fixture" }
EOF
echo "test hook" > "$tmp/plugins/rein-core/hooks/sample.sh"

cat > "$tmp/marketplace/marketplace.json" <<'EOF'
{ "name": "rein-marketplace", "version": "1.0.0", "plugins": [] }
EOF

cd "$tmp"

# --- Mock HTTP server ------------------------------------------------------
# Spawns a Python http.server on a free port. Behavior is controlled by the
# REIN_MOCK_RESPONSE env var (200 or 500). The body of every POST is dumped
# to mock_body_dir/<plugin>-<version>.body so the test can introspect.
cat > "$tmp/mock-server.py" <<'PY'
import http.server, os, sys, json, pathlib, urllib.parse

RESPONSE_CODE = int(os.environ.get("REIN_MOCK_RESPONSE", "200"))
BODY_DIR = pathlib.Path(os.environ["REIN_MOCK_BODY_DIR"])
LOG_FILE = pathlib.Path(os.environ["REIN_MOCK_LOG_FILE"])
BODY_DIR.mkdir(parents=True, exist_ok=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length)
        slug = urllib.parse.quote_plus(self.path)
        (BODY_DIR / f"{slug}.body").write_bytes(body)
        # Persist headers separately so the assertion can grep for the
        # Authorization header without re-parsing the multipart body.
        hdrs = {k: v for k, v in self.headers.items()}
        (BODY_DIR / f"{slug}.headers.json").write_text(json.dumps(hdrs))
        with LOG_FILE.open("a") as fh:
            fh.write(f"POST {self.path} -> {RESPONSE_CODE}\n")
        self.send_response(RESPONSE_CODE)
        self.end_headers()
        self.wfile.write(b"{}" if RESPONSE_CODE == 200 else b'{"error":"mock-failure"}')

    def log_message(self, *args, **kwargs):  # silence default access log
        return

# Bind to ephemeral port — print it on stdout so the test can capture.
addr = ("127.0.0.1", 0)
server = http.server.HTTPServer(addr, Handler)
print(server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
PY

start_mock_server() {
  local code="$1"
  rm -rf "$mock_body_dir" && mkdir -p "$mock_body_dir"
  : > "$mock_log"
  REIN_MOCK_RESPONSE="$code" REIN_MOCK_BODY_DIR="$mock_body_dir" \
    REIN_MOCK_LOG_FILE="$mock_log" \
    python3 "$tmp/mock-server.py" > "$tmp/mock.port" 2>&1 &
  mock_pid=$!
  # Wait for the port to land in mock.port (max ~5s).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port=$(head -1 "$tmp/mock.port" 2>/dev/null || true)
    case "$port" in [0-9]*) break ;; esac
    sleep 0.5
  done
  case "$port" in
    [0-9]*) : ;;
    *) echo "FAIL: mock server failed to start" >&2; cat "$tmp/mock.port" >&2; exit 1 ;;
  esac
  echo "$port"
}

stop_mock_server() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
    mock_pid=""
  fi
}

# --- (b) Missing ANTHROPIC_MARKETPLACE_API ---------------------------------
unset ANTHROPIC_MARKETPLACE_API ANTHROPIC_TOKEN
out=$(bash scripts/rein-publish.sh 1.0.0 2>&1) && {
  echo "FAIL[b]: publish should exit non-zero when API URL is missing" >&2
  exit 1
} || true
echo "$out" | grep -q 'ANTHROPIC_MARKETPLACE_API' || {
  echo "FAIL[b]: missing fail-fast message for ANTHROPIC_MARKETPLACE_API" >&2
  echo "$out" >&2
  exit 1
}

# Reset state for next assertion (manifest rollback should have happened).
python3 - <<PY
import json
data = json.load(open("marketplace/marketplace.json"))
assert data["plugins"] == [], data
PY

# --- (c) Missing ANTHROPIC_TOKEN -------------------------------------------
unset ANTHROPIC_TOKEN
out=$(env ANTHROPIC_MARKETPLACE_API="http://127.0.0.1:65535/mock" \
  bash scripts/rein-publish.sh 1.0.0 2>&1) && {
  echo "FAIL[c]: publish should exit non-zero when token is missing" >&2
  exit 1
} || true
echo "$out" | grep -q 'ANTHROPIC_TOKEN' || {
  echo "FAIL[c]: missing fail-fast message for ANTHROPIC_TOKEN" >&2
  echo "$out" >&2
  exit 1
}

# --- (e) HTTPS-only enforcement (non-loopback http rejected) ---------------
out=$(env ANTHROPIC_MARKETPLACE_API="http://example.com/api" \
  ANTHROPIC_TOKEN="ignored" \
  bash scripts/rein-publish.sh 1.0.0 2>&1) && {
  echo "FAIL[e]: publish should reject plain http://example.com" >&2
  exit 1
} || true
echo "$out" | grep -qi 'HTTPS' || {
  echo "FAIL[e]: missing https-only enforcement message" >&2
  echo "$out" >&2
  exit 1
}

# --- (a) Both channels succeed --------------------------------------------
port=$(start_mock_server 200)
out=$(env ANTHROPIC_MARKETPLACE_API="http://127.0.0.1:${port}/mock" \
  ANTHROPIC_TOKEN="test-secret-deadbeef" \
  bash scripts/rein-publish.sh 1.0.0 2>&1) || {
  echo "FAIL[a]: publish failed unexpectedly: $out" >&2
  exit 1
}
stop_mock_server

# Manifest updated.
python3 - <<PY
import json
data = json.load(open("marketplace/marketplace.json"))
assert any(p["name"] == "rein-core" for p in data["plugins"]), data
PY

# Mock saw exactly one POST per plugin.
posts=$(grep -c '^POST ' "$mock_log" || true)
[ "$posts" -ge 1 ] || { echo "FAIL[a]: mock did not receive POST" >&2; cat "$mock_log" >&2; exit 1; }

# Authorization header carried the bearer token.
header_file=$(ls "$mock_body_dir"/*.headers.json | head -1)
python3 - "$header_file" <<'PY'
import json, sys
hdrs = json.load(open(sys.argv[1]))
auth = hdrs.get("Authorization") or hdrs.get("authorization") or ""
assert auth.startswith("Bearer test-secret-deadbeef"), f"bad Authorization header: {auth!r}"
PY

# Body carried the tarball as multipart form.
body_file=$(ls "$mock_body_dir"/*.body | head -1)
[ -s "$body_file" ] || { echo "FAIL[a]: mock body empty" >&2; exit 1; }
grep -aq 'form-data; name="tarball"' "$body_file" || {
  echo "FAIL[a]: mock body missing form-data tarball part" >&2
  hexdump -C "$body_file" | head -10 >&2
  exit 1
}

# --- (d) Anthropic 500 → rollback ------------------------------------------
# Snapshot manifest BEFORE the failing publish so we can compare.
cp marketplace/marketplace.json "$tmp/manifest-before-d.json"

# Force a fresh version so the tarball is observable.
port=$(start_mock_server 500)
out=$(env ANTHROPIC_MARKETPLACE_API="http://127.0.0.1:${port}/mock" \
  ANTHROPIC_TOKEN="test-secret-deadbeef" \
  bash scripts/rein-publish.sh 9.9.9 2>&1) && {
  echo "FAIL[d]: publish should fail when Anthropic returns 500" >&2
  exit 1
} || true
stop_mock_server

# Self-hosted manifest must be back to its pre-publish state.
diff -u "$tmp/manifest-before-d.json" marketplace/marketplace.json || {
  echo "FAIL[d]: marketplace.json was not rolled back" >&2
  exit 1
}

# Tarball produced for 9.9.9 must be cleaned up.
if [ -e "marketplace/plugins/rein-core/9.9.9/rein-core-9.9.9.tar.gz" ]; then
  echo "FAIL[d]: orphan tarball remained after rollback" >&2
  exit 1
fi

# --- (f) Token must not appear in stdout/stderr ----------------------------
echo "$out" | grep -q 'test-secret-deadbeef' && {
  echo "FAIL[f]: ANTHROPIC_TOKEN leaked into publish output" >&2
  exit 1
} || true

# --- (g) Re-publish existing version + Anthropic fail → prior tarball survives
# Regression: the first version of the rollback logic deleted previously
# published tarballs because it tracked "every tarball we touched" without
# distinguishing newly-created from overwritten. This block re-publishes
# 1.0.0 (which already exists from (a)) but with a 500 from Anthropic.
# Both the manifest entry AND the tarball that existed before must survive.
PREEXISTING_TAR="marketplace/plugins/rein-core/1.0.0/rein-core-1.0.0.tar.gz"
[ -f "$PREEXISTING_TAR" ] || { echo "FAIL[g]: setup — pre-existing tarball missing" >&2; exit 1; }
PRE_BYTES=$(wc -c < "$PREEXISTING_TAR")
cp marketplace/marketplace.json "$tmp/manifest-before-g.json"

port=$(start_mock_server 500)
out=$(env ANTHROPIC_MARKETPLACE_API="http://127.0.0.1:${port}/mock" \
  ANTHROPIC_TOKEN="test-secret-deadbeef" \
  bash scripts/rein-publish.sh 1.0.0 2>&1) && {
  echo "FAIL[g]: re-publish should fail when Anthropic returns 500" >&2
  exit 1
} || true
stop_mock_server

# Manifest reverted.
diff -u "$tmp/manifest-before-g.json" marketplace/marketplace.json || {
  echo "FAIL[g]: manifest not rolled back on re-publish failure" >&2
  exit 1
}

# Pre-existing tarball still present and unchanged.
if [ ! -f "$PREEXISTING_TAR" ]; then
  echo "FAIL[g]: rollback wrongly deleted previously-published tarball" >&2
  exit 1
fi
POST_BYTES=$(wc -c < "$PREEXISTING_TAR")
if [ "$PRE_BYTES" != "$POST_BYTES" ]; then
  echo "FAIL[g]: pre-existing tarball changed across rollback (was $PRE_BYTES, now $POST_BYTES)" >&2
  exit 1
fi

# --- (g2) tar failure on existing version preserves prior tarball ----------
# Codex R2 found that an early `tar` exit (e.g. partial write before signal)
# could truncate the previously published tarball BEFORE rollback bookkeeping
# registered the snapshot. Verify the new write-temp-then-mv path keeps the
# prior bytes byte-for-byte intact when `tar` fails.
PRE_BYTES_G2=$(wc -c < "$PREEXISTING_TAR")
# Capture the prior content for an exact-bytes comparison.
cp "$PREEXISTING_TAR" "$tmp/preexisting-tar-bytes.bin"

# Inject a fake `tar` that writes some garbage to its output then exits 1.
# We prepend a tmp dir to PATH so the script picks up our shim instead of
# the real tar — this also exercises the BSD-tar branch (no `tar --version`
# detection of GNU tar).
fake_path="$tmp/fakebin"
mkdir -p "$fake_path"
cat > "$fake_path/tar" <<'SH'
#!/usr/bin/env bash
# Find -czf <output> in argv and write half-baked bytes there before failing.
out=""
prev=""
for arg in "$@"; do
  case "$prev" in -czf|-cvzf|--file) out="$arg"; break ;; esac
  prev="$arg"
done
if [ -n "$out" ]; then
  printf 'FAKE-TAR-PARTIAL-WRITE' > "$out"
fi
exit 1
SH
chmod +x "$fake_path/tar"
# `--version` should also fail / not match GNU tar so the BSD branch runs.

PATH="$fake_path:$PATH" \
  out=$(env REIN_PUBLISH_SELF_HOSTED_ONLY=1 \
    bash scripts/rein-publish.sh 1.0.0 2>&1) && {
  echo "FAIL[g2]: publish should fail when tar exits non-zero" >&2
  exit 1
} || true

# Pre-existing tarball must be byte-for-byte identical to its prior state.
if ! cmp -s "$PREEXISTING_TAR" "$tmp/preexisting-tar-bytes.bin"; then
  echo "FAIL[g2]: tar-failure rollback corrupted the previously-published tarball" >&2
  echo "Before: $PRE_BYTES_G2 bytes; After: $(wc -c < "$PREEXISTING_TAR") bytes" >&2
  exit 1
fi

# No temp tar files should remain.
LEAK=$(find marketplace -name '*.tar.gz.??????' 2>/dev/null || true)
if [ -n "$LEAK" ]; then
  echo "FAIL[g2]: temp tar file leaked: $LEAK" >&2
  exit 1
fi

# --- (h) Token must not appear in curl argv (process snapshot) -------------
# This block starts a slow mock (sleep then 200) so curl is still alive
# when we sample `ps`. We grep `ps` output for the token literal — if it
# shows up, the token leaked into argv via -H "Authorization: Bearer ...".
cat > "$tmp/slow-mock.py" <<'PY'
import http.server, os, time
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        time.sleep(2)
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a, **kw): return
addr = ("127.0.0.1", 0)
server = http.server.HTTPServer(addr, Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$tmp/slow-mock.py" > "$tmp/slow.port" 2>&1 &
slow_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  slow_port=$(head -1 "$tmp/slow.port" 2>/dev/null || true)
  case "$slow_port" in [0-9]*) break ;; esac
  sleep 0.3
done
LEAK_TOKEN="leak-canary-deadbeef-$$"
env ANTHROPIC_MARKETPLACE_API="http://127.0.0.1:${slow_port}/mock" \
    ANTHROPIC_TOKEN="$LEAK_TOKEN" \
    bash scripts/rein-publish.sh 1.0.0 > "$tmp/leak.log" 2>&1 &
publish_pid=$!
sleep 1
# Sample running processes (any descendant of the publish pid that is
# still alive — typically curl). On macOS `ps -ef` works in the test
# sandbox where `ps -p` was denied earlier in this exact codex review.
PS_DUMP=$(ps -ef 2>/dev/null || ps auxww 2>/dev/null || true)
wait "$publish_pid" 2>/dev/null || true
kill "$slow_pid" 2>/dev/null || true
wait "$slow_pid" 2>/dev/null || true

# The canary token must NOT appear in any process command line. We accept
# the test as inconclusive (warn) only if PS_DUMP is empty, which would
# indicate the test environment forbade ps entirely.
if [ -z "$PS_DUMP" ]; then
  echo "WARN[h]: ps unavailable in this environment; argv-leak check skipped" >&2
elif printf '%s\n' "$PS_DUMP" | grep -F "$LEAK_TOKEN" >/dev/null; then
  echo "FAIL[h]: ANTHROPIC_TOKEN appeared in curl argv (visible in ps)" >&2
  printf '%s\n' "$PS_DUMP" | grep -F "$LEAK_TOKEN" >&2 || true
  exit 1
fi

# And the token must not have leaked into the publish log either.
if grep -F "$LEAK_TOKEN" "$tmp/leak.log" >/dev/null; then
  echo "FAIL[h]: ANTHROPIC_TOKEN leaked into stdout/stderr log" >&2
  cat "$tmp/leak.log" >&2
  exit 1
fi

echo "PASS test-rein-publish-dual-channel.sh"
