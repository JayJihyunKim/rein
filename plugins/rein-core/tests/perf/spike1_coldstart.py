#!/usr/bin/env python3
"""SPIKE-1 콜드스타트 측정 harness (plan Task 1.2, spec §5.4).

측정 대상 6종 구간 (spec §5.4 원문):
  1. 인터프리터 기동      — `python3 -c pass` 서브프로세스 왕복 wall time
  2. Python import        — rein 평가 경로가 쓰는 모듈 전체 import (프로브 내 계측)
  3. policy load          — runtime.load_policies() (프로브 내 계측)
  4. git fact resolution  — platform.git.current_branch() (프로브 내 계측)
  5. SQLite open          — platform.sqlite.open_store() + close (프로브 내 계측)
  6. 대표 tool.pre 평가 왕복 — `bin/rein` 서브프로세스 stdin→stdout 전체 왕복

v1 기준선: `hooks/pre-bash-dispatcher.sh` 에 동일 PreToolUse(Bash) envelope 를
stdin 으로 넣은 전체 체인 왕복 (CLAUDE_PLUGIN_ROOT 설정, cwd=repo root).

cold/warm 정의:
  - cold: 각 반복 직전에 rein 패키지 아래 `__pycache__` 전부 삭제 (bytecode
    cache 무효화) + 매 반복 새 인터프리터 프로세스. OS page cache 는 purge
    하지 않는다 (macOS 에서 root 필요 — 리포트에 명시).
  - warm: 계측 전 warmup 1회로 `__pycache__` 를 채운 뒤, cache 유지 상태로
    반복. 매 반복 새 프로세스인 것은 동일 (실제 hook 호출 패턴과 일치).

unittest discover 에 잡히지 않는 스크립트형 harness 다 (파일명이 test* 아님 —
의도적, 유지). 실행:

    python3 plugins/rein-core/tests/perf/spike1_coldstart.py [--iterations 30]

측정 잔여물은 전부 임시 디렉토리에만 남긴다 (저장소 트리 잔여물 0 —
`__pycache__` 는 gitignore 대상이라 무방).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(HERE))  # plugins/rein-core
REPO_ROOT = os.path.dirname(os.path.dirname(PLUGIN_ROOT))
BIN_REIN = os.path.join(PLUGIN_ROOT, "bin", "rein")
V1_HOOK = os.path.join(PLUGIN_ROOT, "hooks", "pre-bash-dispatcher.sh")
PACKAGE_DIR = os.path.join(PLUGIN_ROOT, "rein")

SUBPROCESS_TIMEOUT_SECONDS = 60

# 대표 이벤트 — v1/v2 양쪽에 동일 envelope 를 준다 (공정 비교).
EVENT_ENVELOPE = json.dumps(
    {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hello"},
    }
)

MATCHING_POLICY_ID = "10-review-gate"
# requirement 이름은 v2 고정 5종만 사용 — Task 1.5 폐쇄 registry 가 로드 시점에
# 미지 이름을 거부하므로, 임의 이름을 쓰면 이후 게이트 재측정에서 harness 가 깨진다.
EXPECTED_MISSING = ["code_review", "security_review"]

# 대표 policy 셋 — 매칭 1건(require 2개 → BLOCK 경로까지 평가) + 비매칭 2건.
POLICY_FILES = {
    "10-review-gate.yaml": (
        "trigger: tool.pre\n"
        "when:\n"
        "  tool: Bash\n"
        "require:\n"
        "  - code_review\n"
        "  - security_review\n"
        "failure_mode: closed\n"
    ),
    "20-post-audit.yaml": (
        "trigger: tool.post\n"
        "require:\n"
        "  - tests_passed\n"
        "failure_mode: open\n"
    ),
    "30-agent-scope.yaml": (
        "trigger: agent.started\n"
        "when:\n"
        "  tool: Task\n"
        "require:\n"
        "  - active_task\n"
        "failure_mode: closed\n"
    ),
}

# 프로브 — 구간 2~5 를 새 인터프리터 안에서 개별 계측해 JSON 으로 출력한다.
PROBE_SOURCE = """\
import json
import sys
import time

package_parent, policy_dir, db_path = sys.argv[1:4]
segments = {}

t0 = time.perf_counter()
sys.path.insert(0, package_parent)
from rein.engine import runtime
from rein.platform import git as git_facts
from rein.platform import sqlite as sqlite_store
from rein.platform.claude import adapter  # noqa: F401 - import cost measurement
import rein.cli  # noqa: F401 - import cost measurement
segments["import_ms"] = (time.perf_counter() - t0) * 1000.0

t0 = time.perf_counter()
policies = runtime.load_policies(policy_dir)
segments["policy_load_ms"] = (time.perf_counter() - t0) * 1000.0

t0 = time.perf_counter()
branch = git_facts.current_branch()
segments["git_fact_ms"] = (time.perf_counter() - t0) * 1000.0

t0 = time.perf_counter()
store = sqlite_store.open_store(db_path)
store.close()
segments["sqlite_open_ms"] = (time.perf_counter() - t0) * 1000.0

# sanity: 평가 경로가 실제로 BLOCK 을 내는지 확인 (계측값에는 미포함)
decision = runtime.evaluate(
    "tool.pre", {"tool": "Bash", "git.branch": branch}, policies
)
if decision["decision"] != "BLOCK":
    raise SystemExit("probe sanity failed: expected BLOCK, got %r" % decision)

json.dump(segments, sys.stdout)
"""


def percentile(samples, pct):
    """선형 보간 percentile (stdlib quantiles 는 3.9 에서 방식 상이 — 자체 구현)."""
    ordered = sorted(samples)
    if not ordered:
        return float("nan")
    k = (len(ordered) - 1) * (pct / 100.0)
    lower = int(k)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (k - lower)


def summarize(samples):
    return {
        "n": len(samples),
        "p50_ms": round(percentile(samples, 50), 2),
        "p95_ms": round(percentile(samples, 95), 2),
        "min_ms": round(min(samples), 2),
        "max_ms": round(max(samples), 2),
    }


def clear_pycache():
    """rein 패키지 아래 __pycache__ 전부 삭제 — cold 반복의 전제."""
    for dirpath, dirnames, _filenames in os.walk(PACKAGE_DIR):
        if "__pycache__" in dirnames:
            shutil.rmtree(os.path.join(dirpath, "__pycache__"), ignore_errors=True)


def timed_run(cmd, stdin_text, cwd, env):
    """서브프로세스 1회 실행 wall time (ms) + CompletedProcess."""
    started = time.perf_counter()
    proc = subprocess.run(
        cmd,
        input=stdin_text,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        timeout=SUBPROCESS_TIMEOUT_SECONDS,
        check=False,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return elapsed_ms, proc


def fail(message, proc=None):
    sys.stderr.write("spike1: {}\n".format(message))
    if proc is not None:
        sys.stderr.write("  rc={}\n  stdout: {}\n  stderr: {}\n".format(
            proc.returncode, proc.stdout.strip(), proc.stderr.strip()
        ))
    raise SystemExit(1)


def measure_v2_iteration(ctx, cold):
    """v2 구간 6종 1회 계측. cold 면 각 서브프로세스 직전에 pycache 삭제."""
    row = {}

    # 구간 1: 인터프리터 기동 (rein 미포함 순수 기동)
    if cold:
        clear_pycache()
    elapsed, proc = timed_run(
        [sys.executable, "-c", "pass"], "", REPO_ROOT, ctx["base_env"]
    )
    if proc.returncode != 0:
        fail("interpreter probe failed", proc)
    row["interpreter_ms"] = elapsed

    # 구간 2~5: 프로브 (새 인터프리터 안에서 개별 계측)
    if cold:
        clear_pycache()
    _elapsed, proc = timed_run(
        [
            sys.executable,
            ctx["probe_path"],
            PLUGIN_ROOT,
            ctx["policy_dir"],
            ctx["db_path"],
        ],
        "",
        REPO_ROOT,
        ctx["base_env"],
    )
    if proc.returncode != 0:
        fail("segment probe failed", proc)
    row.update(json.loads(proc.stdout))

    # 구간 6: bin/rein 전체 왕복 (stdin → decision JSON stdout)
    if cold:
        clear_pycache()
    elapsed, proc = timed_run(
        [sys.executable, BIN_REIN], EVENT_ENVELOPE, REPO_ROOT, ctx["v2_env"]
    )
    if proc.returncode != 0:
        fail("bin/rein roundtrip failed", proc)
    decision = json.loads(proc.stdout)
    if (
        decision.get("decision") != "BLOCK"
        or decision.get("policy") != MATCHING_POLICY_ID
        or decision.get("missing_requirements") != EXPECTED_MISSING
    ):
        fail("bin/rein returned unexpected decision: {!r}".format(decision))
    row["roundtrip_ms"] = elapsed
    return row


def measure_v1_iteration(ctx, cold):
    """v1 hook 체인 1회 계측 — pre-bash-dispatcher.sh 전체 왕복."""
    if cold:
        clear_pycache()  # bash 체인엔 사실상 무영향이나 cold 정의를 대칭으로 유지
    elapsed, proc = timed_run(
        ["bash", V1_HOOK], EVENT_ENVELOPE, REPO_ROOT, ctx["v1_env"]
    )
    if proc.returncode != 0:
        fail("v1 dispatcher exited non-zero", proc)
    return {"roundtrip_ms": elapsed}


def run_phase(measure, ctx, iterations, cold, warmup):
    """한 phase(cold 또는 warm) 실행 → 구간별 샘플 리스트."""
    if warmup:
        measure(ctx, cold=False)  # warm phase 진입 전 cache 채움
    samples = {}
    for _ in range(iterations):
        row = measure(ctx, cold=cold)
        for key, value in row.items():
            samples.setdefault(key, []).append(value)
    return {key: summarize(values) for key, values in samples.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument(
        "--skip-v1", action="store_true", help="v1 기준선 측정 생략 (개발 반복용)"
    )
    args = parser.parse_args()

    if not os.path.isfile(BIN_REIN):
        fail("bin/rein not found at {}".format(BIN_REIN))
    if not os.path.isfile(V1_HOOK):
        fail("v1 hook not found at {}".format(V1_HOOK))

    temp_root = tempfile.mkdtemp(prefix="spike1-")
    try:
        policy_dir = os.path.join(temp_root, "policies")
        os.makedirs(policy_dir)
        for name, body in POLICY_FILES.items():
            with open(os.path.join(policy_dir, name), "w", encoding="utf-8") as fh:
                fh.write(body)
        probe_path = os.path.join(temp_root, "probe.py")
        with open(probe_path, "w", encoding="utf-8") as fh:
            fh.write(PROBE_SOURCE)
        db_path = os.path.join(temp_root, "spike1.sqlite")

        base_env = dict(os.environ)
        # 프로브·bin/rein 이 저장소 트리에 bytecode 를 남기는 건 gitignore 라
        # 무방하지만, 임시 프로브 스크립트 자신의 pyc 은 temp 에만 남는다.
        v2_env = dict(base_env)
        v2_env["REIN_POLICY_DIR"] = policy_dir
        v2_env["REIN_DB_PATH"] = db_path
        v1_env = dict(base_env)
        v1_env["CLAUDE_PLUGIN_ROOT"] = PLUGIN_ROOT

        ctx = {
            "base_env": base_env,
            "v2_env": v2_env,
            "v1_env": v1_env,
            "policy_dir": policy_dir,
            "probe_path": probe_path,
            "db_path": db_path,
        }

        results = {
            "meta": {
                "iterations": args.iterations,
                "python": sys.version.split()[0],
                "platform": sys.platform,
                "bin_rein": os.path.relpath(BIN_REIN, REPO_ROOT),
                "v1_hook": os.path.relpath(V1_HOOK, REPO_ROOT),
                "event": json.loads(EVENT_ENVELOPE),
                "cold_definition": "rm rein/**/__pycache__ before each subprocess; "
                "fresh interpreter per run; OS page cache NOT purged",
                "warm_definition": "one unmeasured warmup populates __pycache__; "
                "fresh interpreter per run",
            },
            "v2": {},
            "v1": {},
        }

        results["v2"]["cold"] = run_phase(
            measure_v2_iteration, ctx, args.iterations, cold=True, warmup=False
        )
        results["v2"]["warm"] = run_phase(
            measure_v2_iteration, ctx, args.iterations, cold=False, warmup=True
        )
        if not args.skip_v1:
            results["v1"]["cold"] = run_phase(
                measure_v1_iteration, ctx, args.iterations, cold=True, warmup=False
            )
            results["v1"]["warm"] = run_phase(
                measure_v1_iteration, ctx, args.iterations, cold=False, warmup=True
            )

        json.dump(results, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)
        clear_pycache()  # 저장소 트리 잔여물 최소화 (gitignore 대상이지만 정리)
    return 0


if __name__ == "__main__":
    sys.exit(main())
