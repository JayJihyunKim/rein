#!/usr/bin/env python3
"""v2 Phase 6 3회차 재리뷰 High 1/3 — changeset 해시 lazy 전환 비용 측정 harness.

측정 목적 (수리 보고서 `docs/reports/v2-phase6-cost-measurement.md` 의
근거 스크립트): `rein/cli/__init__.py::_build_facts()` 가 changeset
해시(`changeset.digest`/`changeset.sensitive_digest`/`changeset.tag`)를
값으로 미리 계산하던(예전 "declared heuristic" — trigger 만 보고
`when` 은 무시) 것을 `_build_fact_resolvers()` 의 lazy resolver 로
바꾼 수리(High 1)가, 실제로 (a) 파일 편집(Edit) 이벤트에서 이 계산을
구조적으로 없애는지, (b) 없앨 때 시간이 얼마나 줄어드는지를 재현
가능하게 증명한다.

## 방법론 — "before" 를 어떻게 재구성했는가 (정직하게 명시)

이 수리 사이클(Phase 6 3회차)은 이전 사이클(Task 6.1)의 산출물 위에서
전부 **미커밋 working tree 변경**으로 진행됐다 — `git log` 최상단
커밋은 Task 6.1 착수 이전 상태(Phase 5 완료 시점)라, `git show HEAD:...`
로 "고치기 직전" 스냅샷을 복원할 방법이 없다(그 스냅샷 자체가 커밋된
적이 없다). 그래서 이 harness 는 **"before" 동작을 현재 저장소에 여전히
남아 있는 공유 헬퍼(`rein.cli._git_changeset_facts`/
`_declared_requirements`/`_EVIDENCE_ISSUED_REQUIREMENTS`)로 직접
재구성**한다 — 이 헬퍼들은 수리 후에도 그대로 존재한다(삭제된 것은
"언제 부르는가"라는 오케스트레이션 한 곳뿐, 헬퍼 자체는 수리 전후
동일하다). `_reconstructed_before_build_facts()` 가 수리 전
`_build_facts()` 의 changeset 계산 블록을 코드 그대로 재현한다(아래
주석에 그 대응 관계를 명시) — "예전 코드가 이랬을 것이다" 는 추측이
아니라, 실제로 삭제된 블록의 조건문·호출을 동일하게 재현한 것이다.

## 측정 두 갈래

1. **구조적 증명 (call count)** — `rein.cli._git_changeset_facts` 를
   계측 wrapper 로 감싸, 수리 후 실제 프로덕션 경로
   (`_build_facts()` + `_build_fact_resolvers()` + `runtime.evaluate()`)
   가 파일 편집 이벤트에서 이 함수를 **0회** 호출함을 확인한다 — "시간이
   줄었다" 이전에 "애초에 안 부른다"를 먼저 구조적으로 고정한다.
2. **비용 측정 (wall time)** — 같은 fixture(git 저장소 + N개 파일)에서
   "before"(재구성된 즉시 계산)와 "after"(실제 lazy 경로, 파일 편집
   이벤트) 의 in-process wall time 을 N_ITER 회 반복해 percentile 로
   비교한다. 부가로 `bin/rein` 전체 왕복(subprocess, spike1 과 동일
   방법론)도 측정해 실제 hook latency 문맥에서의 크기를 함께 보고한다.

cold/warm 정의는 SPIKE-1(`tests/perf/spike1_coldstart.py`)과 동일한
관례를 따른다 — in-process 측정은 프로세스 재기동 비용을 배제하고
"changeset 해시 계산 자체"의 비용만 격리한다(hook 실제 체감은 그 위에
인터프리터 기동 비용이 얹힌다 — 왕복 측정이 그 문맥을 보완한다).

unittest discover 에 잡히지 않는 스크립트형 harness 다(파일명이 test*
아님 — `tests/perf/spike1_coldstart.py`/`spike2_capture_cost.sh` 와
동일 관례). 실행:

    python3 plugins/rein-core/tests/perf/lazy_changeset_hash_cost.py \
        [--iterations 20] [--files 150] [--file-bytes 8192]

측정 잔여물은 전부 임시 디렉토리에만 남긴다(저장소 트리 잔여물 0).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(os.path.dirname(HERE))  # plugins/rein-core
REPO_ROOT = os.path.dirname(os.path.dirname(PLUGIN_ROOT))
BIN_REIN = os.path.join(PLUGIN_ROOT, "bin", "rein")
DEFAULT_POLICY_DIR = os.path.join(PLUGIN_ROOT, "policies", "default")

if PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, PLUGIN_ROOT)

SUBPROCESS_TIMEOUT_SECONDS = 60


def percentile(samples, pct):
    """선형 보간 percentile — spike1_coldstart.py 와 동일 구현(관례 재사용)."""
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
        "mean_ms": round(sum(samples) / len(samples), 3),
        "p50_ms": round(percentile(samples, 50), 3),
        "p95_ms": round(percentile(samples, 95), 3),
        "min_ms": round(min(samples), 3),
        "max_ms": round(max(samples), 3),
    }


def _init_fixture_repo(project_root, file_count, file_bytes):
    """git 저장소 + N개 미추적 파일 — WORKTREE changeset 비용이 측정 가능한 크기가 되도록."""
    subprocess.run(["git", "init", "-q"], cwd=project_root, check=True)
    subprocess.run(
        ["git", "config", "user.email", "t@example.com"],
        cwd=project_root,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "t"], cwd=project_root, check=True
    )
    src_dir = os.path.join(project_root, "src")
    os.makedirs(src_dir, exist_ok=True)
    # 초기 커밋 — 편집 대상 파일 하나(git.commit 시나리오·Edit 시나리오
    # 양쪽이 참조).
    target_path = os.path.join(src_dir, "target.py")
    with open(target_path, "w", encoding="utf-8") as handle:
        handle.write("def handler():\n    return 1\n")
    subprocess.run(["git", "add", "src/target.py"], cwd=project_root, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "init"], cwd=project_root, check=True
    )
    # N 개의 미추적 파일 — 실전 저장소의 "동시에 여러 파일이 바뀐 작업
    # 트리"를 흉내낸다. WORKTREE changeset 은 이 전부를 포함한다.
    payload = ("x" * file_bytes).encode("utf-8")
    for i in range(file_count):
        with open(
            os.path.join(src_dir, "generated_{:04d}.txt".format(i)), "wb"
        ) as handle:
            handle.write(payload)
    return target_path


def _edit_event(target_path):
    return {
        "name": "tool.pre",
        "tool": "Edit",
        "payload": {
            "file_path": target_path,
            "old_string": "1",
            "new_string": "2",
        },
    }


def _reconstructed_before_build_facts(event, project_root, policies):
    """수리 전 `_build_facts()` 의 changeset 계산 블록 재구성 (방법론 절 참조).

    삭제된 원본 블록(수리 전 `rein/cli/__init__.py::_build_facts()`,
    Phase 6 수리 워커 F/H 산출물)은 다음과 같았다:

        declared = _declared_requirements(policies, event.get("name"))
        if project_root and (declared & _EVIDENCE_ISSUED_REQUIREMENTS):
            digest, sensitive_digest, tag, paths = _git_changeset_facts(
                project_root
            )
            ...  # facts[...] = digest 등

    이 함수는 그 조건문과 호출을 동일하게 재현한다 — `_git_changeset_
    facts`/`_declared_requirements`/`_EVIDENCE_ISSUED_REQUIREMENTS` 는
    삭제되지 않고 지금도 `rein.cli` 에 그대로 존재하는 공유 헬퍼다
    (삭제된 것은 "이 헬퍼를 즉시 호출하는 오케스트레이션" 뿐).
    """
    from rein.cli import _EVIDENCE_ISSUED_REQUIREMENTS  # noqa: E402
    from rein.cli import _declared_requirements  # noqa: E402
    from rein.cli import _git_changeset_facts  # noqa: E402

    declared = _declared_requirements(policies, event.get("name"))
    if project_root and (declared & _EVIDENCE_ISSUED_REQUIREMENTS):
        return _git_changeset_facts(project_root)
    return None, None, None, None, None


def _default_policies():
    from rein.engine import runtime  # noqa: E402

    return runtime.load_policies(DEFAULT_POLICY_DIR)


def measure_call_count_after_fix(project_root, target_path, policies):
    """구조적 증명 — 실제 프로덕션 경로가 Edit 이벤트에서 changeset 계산을 0회 호출하는가."""
    import rein.cli as rein_cli  # noqa: E402
    from rein.engine import runtime  # noqa: E402
    from unittest import mock

    event = _edit_event(target_path)
    calls = []
    original = rein_cli._git_changeset_facts

    def counting(*args, **kwargs):
        calls.append(1)
        return original(*args, **kwargs)

    with mock.patch.object(rein_cli, "_git_changeset_facts", counting):
        facts = rein_cli._build_facts(event, project_root, policies=policies)
        resolvers = rein_cli._build_fact_resolvers(event, project_root)
        decision = runtime.evaluate(
            "tool.pre", facts, policies, fact_resolvers=resolvers
        )
    return len(calls), decision


def measure_before_after_in_process(project_root, target_path, policies, iterations):
    """in-process wall time — "before"(즉시 계산 재구성) vs "after"(lazy, 미조회)."""
    event = _edit_event(target_path)

    before_samples = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        _reconstructed_before_build_facts(event, project_root, policies)
        before_samples.append((time.perf_counter() - t0) * 1000.0)

    import rein.cli as rein_cli  # noqa: E402
    from rein.engine import runtime  # noqa: E402

    after_samples = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        facts = rein_cli._build_facts(event, project_root, policies=policies)
        resolvers = rein_cli._build_fact_resolvers(event, project_root)
        runtime.evaluate("tool.pre", facts, policies, fact_resolvers=resolvers)
        after_samples.append((time.perf_counter() - t0) * 1000.0)

    return summarize(before_samples), summarize(after_samples)


def measure_roundtrip(project_root, target_path, policy_dir, iterations):
    """`bin/rein` 전체 왕복(subprocess) — 실제 hook 문맥에서의 크기 참고치.

    spike1_coldstart.py 의 구간 6(전체 왕복) 과 동일한 측정 방법론
    (subprocess wall time, warm — 인터프리터 재기동은 포함하되 cold
    __pycache__ 삭제는 하지 않는다) 을 재사용한다.
    """
    envelope = json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Edit",
            "tool_input": {
                "file_path": target_path,
                "old_string": "1",
                "new_string": "2",
            },
        }
    )
    env = dict(os.environ)
    env["REIN_POLICY_DIR"] = policy_dir
    env["REIN_PROJECT_ROOT"] = project_root
    env["REIN_DB_PATH"] = ":memory:"

    # warmup 1회 (미계측) — __pycache__ 채움, spike1 과 동일 관례.
    subprocess.run(
        [sys.executable, BIN_REIN],
        input=envelope,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
        env=env,
        timeout=SUBPROCESS_TIMEOUT_SECONDS,
        check=False,
    )

    samples = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        proc = subprocess.run(
            [sys.executable, BIN_REIN],
            input=envelope,
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            env=env,
            timeout=SUBPROCESS_TIMEOUT_SECONDS,
            check=False,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        if proc.returncode != 0:
            sys.stderr.write(
                "lazy_changeset_hash_cost: bin/rein roundtrip failed rc={} "
                "stdout={!r} stderr={!r}\n".format(
                    proc.returncode, proc.stdout, proc.stderr
                )
            )
            raise SystemExit(1)
        samples.append(elapsed_ms)
    return summarize(samples)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument(
        "--files", type=int, default=150, help="fixture 작업 트리의 미추적 파일 수"
    )
    parser.add_argument(
        "--file-bytes", type=int, default=8192, help="파일 1개당 바이트 수"
    )
    args = parser.parse_args()

    if not os.path.isfile(BIN_REIN):
        sys.stderr.write(
            "lazy_changeset_hash_cost: bin/rein not found at {}\n".format(BIN_REIN)
        )
        return 1

    temp_root = tempfile.mkdtemp(prefix="lazy-changeset-cost-")
    try:
        project_root = os.path.join(temp_root, "proj")
        os.makedirs(project_root)
        target_path = _init_fixture_repo(project_root, args.files, args.file_bytes)
        policies = _default_policies()

        call_count, decision = measure_call_count_after_fix(
            project_root, target_path, policies
        )
        before_summary, after_summary = measure_before_after_in_process(
            project_root, target_path, policies, args.iterations
        )
        roundtrip_summary = measure_roundtrip(
            project_root, target_path, DEFAULT_POLICY_DIR, args.iterations
        )

        delta_ms = round(before_summary["p50_ms"] - after_summary["p50_ms"], 3)
        results = {
            "meta": {
                "harness": "plugins/rein-core/tests/perf/lazy_changeset_hash_cost.py",
                "iterations": args.iterations,
                "fixture": {
                    "files": args.files,
                    "file_bytes": args.file_bytes,
                    "total_bytes": args.files * args.file_bytes,
                },
                "python": sys.version.split()[0],
                "platform": sys.platform,
                "scenario": "PreToolUse Edit event against the default "
                "policy set (policies/default/*.yaml) — the exact "
                "scenario the independent reviewer reported as "
                "still hashing the changeset despite cost gating "
                "(Phase 6 3rd-round review, High 1)",
                "methodology_note": (
                    "'before' is a faithful reconstruction of the removed "
                    "eager-computation block using the still-present "
                    "shared helpers (_git_changeset_facts/"
                    "_declared_requirements/_EVIDENCE_ISSUED_REQUIREMENTS) "
                    "— no committed pre-fix snapshot exists to check out "
                    "(this cycle's work sits entirely uncommitted on top "
                    "of Phase 5). See module docstring for the exact "
                    "reconstructed block."
                ),
            },
            "structural_proof": {
                "git_changeset_facts_call_count_after_fix": call_count,
                "decision_reason": decision["reason"],
                "note": "0 means the fix structurally prevents the "
                "changeset hash computation from running at all for "
                "this Edit event — not just 'happens to be fast'",
            },
            "in_process_cost": {
                "before_reconstructed_eager": before_summary,
                "after_lazy_not_invoked": after_summary,
                "delta_p50_ms": delta_ms,
            },
            "roundtrip_bin_rein_after_fix": roundtrip_summary,
        }
        json.dump(results, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    finally:
        import shutil

        shutil.rmtree(temp_root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
