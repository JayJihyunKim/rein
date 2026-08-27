"""plan Task 5.3 — Tracker: planned WorkGraph vs 관측 실행 대조 테스트 (spec §4.4, §4.3, §2.3).

fixture 는 실제 platform native hook 페이로드 형태를 만들고
`adapter.normalize_event()` 로 정규화한 뒤 tracker 에 주입한다 — 이는
(a) plan Task 5.3 "이벤트 시퀀스(4 native event kinds) 주입" 요구를
그대로 따르는 것이자, (b) adapter 의 agent 계열 payload 추출 추가분을
end-to-end 로 함께 검증한다. `tests/orchestration/` 는
`test_kernel_isolation.py` 의 native 이름 부재 검사(rein/ 트리 대상)
밖이므로 이 파일에서 native hook 이름을 직접 쓰는 것은 안전하다 — 반면
`tracker.py` 자신은 그 검사 대상이라 중립 이벤트 이름(`task.created`
등)만 다룬다.

고정 대상 4묶음 (plan Task 5.3 Steps 1 원문):
1. planned fixture + 이벤트 시퀀스 주입 → 대조 레코드 존재.
2. 불일치 표기 — (a) planned-but-unexecuted, (b) observed-but-unplanned.
3. `degraded` 필드 슬롯 + 기록용 공개 메서드.
4. 기록은 로컬 runtime state(파일시스템 없이도 동작 + 영속화 시 append).
"""
import json
import os
import stat
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.orchestration import tracker  # noqa: E402
from rein.platform.claude import adapter  # noqa: E402
from rein.platform.storage import local  # noqa: E402

# F2 fix-review scope: the cross-module import ban is lifted for tests only —
# tracker.py itself still does not import work_graph/work_unit (see its
# module docstring "Import 경계"). This try/except lets the integration test
# below degrade to a skip if the sibling wave worker (Task 5.1,
# WorkGraph.to_planned_units()) hasn't landed yet at collection time.
try:
    from rein.orchestration import work_graph as work_graph_module  # noqa: E402
    from rein.orchestration import work_unit as work_unit_module  # noqa: E402
except ImportError:  # pragma: no cover - sibling wave module absent
    work_graph_module = None
    work_unit_module = None

_TO_PLANNED_UNITS_AVAILABLE = bool(
    work_graph_module is not None
    and hasattr(work_graph_module.WorkGraph, "to_planned_units")
)


# ---------------------------------------------------------------------------
# 공통 fixture — native hook 페이로드 (adapter.normalize_event() 입력)
# ---------------------------------------------------------------------------

_COMMON_HOOK_BASE = {
    "session_id": "sess-1",
    "transcript_path": "/tmp/example/transcript.jsonl",
    "cwd": "/tmp/example",
    "permission_mode": "default",
}


def _agent_started(agent_id, agent_type):
    payload = dict(_COMMON_HOOK_BASE)
    payload["hook_event_name"] = "SubagentStart"
    payload["agent_id"] = agent_id
    payload["agent_type"] = agent_type
    return adapter.normalize_event(payload)


def _agent_stopped(agent_id, agent_type, last_assistant_message="done"):
    # Official SubagentStop fields (verified 2026-08-11 against
    # https://code.claude.com/docs/en/hooks#subagentstop via context7's
    # indexed copy of the docs — see round-2 review finding 1):
    # agent_id, agent_type, agent_transcript_path, last_assistant_message,
    # background_tasks, session_crons, stop_hook_active.
    payload = dict(_COMMON_HOOK_BASE)
    payload["hook_event_name"] = "SubagentStop"
    payload["agent_id"] = agent_id
    payload["agent_type"] = agent_type
    payload["agent_transcript_path"] = "/tmp/example/subagents/{}.jsonl".format(
        agent_id
    )
    payload["last_assistant_message"] = last_assistant_message
    payload["stop_hook_active"] = False
    payload["background_tasks"] = []
    payload["session_crons"] = []
    return adapter.normalize_event(payload)


def _task_created(task_id, task_subject, task_description=None, teammate_name=None):
    # Official TaskCreated fields (verified 2026-08-11 against
    # https://code.claude.com/docs/en/hooks#taskcreated via context7's
    # indexed copy of the docs — a direct WebFetch of the live page was
    # truncated by its own summarizer before reaching the schema section,
    # so context7's copy of the same docs — reproducing the literal
    # example JSON and the TaskCreatedHookInput/TaskCompletedHookInput
    # TypeScript types — is the source of truth here, round-2 review
    # finding 1): task_id, task_subject, task_description?, teammate_name?,
    # team_name?(deprecated). There is NO subagent_type/agent_id/agent_type
    # field on task events, and NO status field either — those only exist
    # on SubagentStart/SubagentStop (agent_id/agent_type) or were never
    # real to begin with (status). teammate_name is the task's CREATOR,
    # not its assignee (finding 1c) — callers must not treat it as an
    # agent-name hint.
    payload = dict(_COMMON_HOOK_BASE)
    payload["hook_event_name"] = "TaskCreated"
    payload["task_id"] = task_id
    payload["task_subject"] = task_subject
    if task_description is not None:
        payload["task_description"] = task_description
    if teammate_name is not None:
        payload["teammate_name"] = teammate_name
    return adapter.normalize_event(payload)


def _task_completed(
    task_id, task_subject, task_description=None, teammate_name=None
):
    # Same official field set as TaskCreated — TaskCompleted carries no
    # separate "status" field (see _task_created docstring above).
    payload = dict(_COMMON_HOOK_BASE)
    payload["hook_event_name"] = "TaskCompleted"
    payload["task_id"] = task_id
    payload["task_subject"] = task_subject
    if task_description is not None:
        payload["task_description"] = task_description
    if teammate_name is not None:
        payload["teammate_name"] = teammate_name
    return adapter.normalize_event(payload)


def _planned_unit(unit_id, assigned_agent, **extra):
    # status="pending" — matches WorkUnit's real status enum
    # (pending/completed/blocked, rein/orchestration/work_unit.py). The
    # fixture previously used "planned", a value WorkUnit itself rejects;
    # Tracker never validated status against that enum (it only checks
    # id/assigned_agent shape), so this was a latent fixture bug that
    # would have broken the very first real WorkGraph→Tracker composition
    # (finding 2, F2 fix review).
    unit = {
        "id": unit_id,
        "objective": "objective for " + unit_id,
        "scope": ["some/path.py"],
        "dependencies": [],
        "assigned_agent": assigned_agent,
        "status": "pending",
        "expected_output": "expected output for " + unit_id,
    }
    unit.update(extra)
    return unit


_PLANNED_WORK_GRAPH = [
    _planned_unit("unit-1", "security-reviewer"),
    _planned_unit("unit-2", "feature-builder"),
    _planned_unit("unit-3", "feature-builder-fix"),  # 절대 실행되지 않는 unit
]


def _fresh_tracker(project_root=None):
    return tracker.Tracker(_PLANNED_WORK_GRAPH, project_root=project_root)


# ---------------------------------------------------------------------------
# 1. 정규화된 이벤트 형태 (adapter 추가분 자체 검증)
# ---------------------------------------------------------------------------


class NormalizedAgentEventShapeTest(unittest.TestCase):
    """adapter 의 agent 계열 payload 추출 — 기존 tool_name/tool_input 추출과
    달리 이벤트별 고유 필드(agent_id/agent_type 등)를 통째로 넘긴다."""

    def test_agent_started_payload_carries_identifying_fields(self):
        event = _agent_started("agent-abc", "security-reviewer")
        self.assertEqual(event["name"], "agent.started")
        self.assertIsNone(event["tool"])
        self.assertEqual(event["payload"]["agent_id"], "agent-abc")
        self.assertEqual(event["payload"]["agent_type"], "security-reviewer")

    def test_agent_payload_excludes_common_base_fields(self):
        event = _agent_started("agent-abc", "security-reviewer")
        for key in ("session_id", "transcript_path", "cwd", "permission_mode"):
            self.assertNotIn(key, event["payload"])

    def test_task_created_payload_carries_task_fields(self):
        # Official field set (round-2 review finding 1): task_id,
        # task_subject, task_description, teammate_name — NOT
        # subagent_type (that field never existed on this event). This
        # assertion was rewritten from the pre-fix shape which asserted a
        # fictional "subagent_type" field.
        event = _task_created(
            "task-xyz",
            "Implement widget",
            task_description="implement widget end to end",
            teammate_name="implementer",
        )
        self.assertEqual(event["name"], "task.created")
        self.assertEqual(event["payload"]["task_id"], "task-xyz")
        self.assertEqual(event["payload"]["task_subject"], "Implement widget")
        self.assertEqual(event["payload"]["teammate_name"], "implementer")
        self.assertNotIn("subagent_type", event["payload"])
        # task_description is not a confirmed identity field — it is a
        # bounded scalar demoted into "extras", not a top-level key.
        self.assertEqual(
            event["payload"]["extras"]["task_description"],
            "implement widget end to end",
        )

    def test_existing_pretooluse_extraction_is_unchanged(self):
        # 회귀 가드 — agent 계열 추가가 기존 tool_name/tool_input 경로를
        # 건드리지 않았는지 이 파일에서도 한 번 더 확인한다.
        event = adapter.normalize_event(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": {"command": "ls"},
            }
        )
        self.assertEqual(event["tool"], "Bash")
        self.assertEqual(event["payload"], {"command": "ls"})


# ---------------------------------------------------------------------------
# 2. planned vs actual 대조 — 매칭 + 불일치 표기
# ---------------------------------------------------------------------------


class ComparisonRecordTest(unittest.TestCase):
    def test_empty_tracker_has_empty_comparison_record(self):
        t = tracker.Tracker(_PLANNED_WORK_GRAPH)
        record = t.comparison_record()
        self.assertEqual(len(record["planned"]), 3)
        self.assertEqual(record["observed"], [])
        self.assertEqual(
            sorted(record["mismatches"]["planned_unexecuted"]),
            ["unit-1", "unit-2", "unit-3"],
        )
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        self.assertIsNone(record["degraded"])

    def test_matched_execution_via_agent_lifecycle_clears_planned_unexecuted(self):
        t = _fresh_tracker()
        t.observe(_agent_started("agent-abc", "security-reviewer"))
        t.observe(_agent_stopped("agent-abc", "security-reviewer"))
        record = t.comparison_record()

        self.assertNotIn("unit-1", record["mismatches"]["planned_unexecuted"])
        matched = [
            execution
            for execution in record["observed"]
            if execution["unit_id"] == "unit-1"
        ]
        self.assertEqual(len(matched), 1)
        self.assertTrue(matched[0]["started"])
        self.assertTrue(matched[0]["stopped"])
        self.assertEqual(matched[0]["events"], ["agent.started", "agent.stopped"])

    def test_matched_execution_via_task_lifecycle_clears_planned_unexecuted(self):
        # Task events carry no name field at all (round-2 finding 1) — the
        # only way to correlate a task.created/task.completed pair to a
        # planned unit is an explicit bind_task() (finding 1b-i), which
        # the prompt layer calls right after TaskCreate returns a task id.
        t = _fresh_tracker()
        t.bind_task("unit-2", "task-xyz")
        t.observe(_task_created("task-xyz", "Implement widget"))
        t.observe(_task_completed("task-xyz", "Implement widget"))
        record = t.comparison_record()

        self.assertNotIn("unit-2", record["mismatches"]["planned_unexecuted"])
        matched = [
            execution
            for execution in record["observed"]
            if execution["unit_id"] == "unit-2"
        ]
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0]["events"], ["task.created", "task.completed"])
        self.assertEqual(matched[0]["correlation"], "bound")

    def test_planned_but_unexecuted_unit_is_marked(self):
        t = _fresh_tracker()
        t.observe(_agent_started("agent-abc", "security-reviewer"))
        t.observe(_agent_stopped("agent-abc", "security-reviewer"))
        record = t.comparison_record()

        # unit-2/unit-3 는 어떤 이벤트도 관측되지 않았다
        self.assertEqual(
            sorted(record["mismatches"]["planned_unexecuted"]),
            ["unit-2", "unit-3"],
        )

    def test_observed_but_unplanned_execution_is_marked(self):
        t = _fresh_tracker()
        t.observe(_agent_started("agent-999", "unexpected-agent"))
        t.observe(_agent_stopped("agent-999", "unexpected-agent"))
        record = t.comparison_record()

        unplanned = record["mismatches"]["unplanned_observed"]
        self.assertEqual(len(unplanned), 1)
        self.assertIsNone(unplanned[0]["unit_id"])
        self.assertEqual(unplanned[0]["assigned_agent"], "unexpected-agent")
        self.assertTrue(unplanned[0]["started"])
        self.assertTrue(unplanned[0]["stopped"])
        # agent_type 이라는 실재하는 이름 신호가 있었는데 매칭에 실패한
        # 경우다 — "unbound"(이름 신호 자체가 없음)와는 다른 확신도.
        self.assertIsNone(unplanned[0]["correlation"])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        # 계획에 있던 3개 unit 은 전부 미실행으로 남는다 (unplanned 실행이
        # 엉뚱한 unit 을 소비하지 않았는지 확인)
        self.assertEqual(
            sorted(record["mismatches"]["planned_unexecuted"]),
            ["unit-1", "unit-2", "unit-3"],
        )

    def test_full_sequence_mixed_matched_and_mismatches(self):
        t = _fresh_tracker()
        t.observe(_agent_started("agent-abc", "security-reviewer"))
        t.observe(_agent_stopped("agent-abc", "security-reviewer"))
        # unit-2 is bound explicitly — task events have no name field to
        # auto-match with (round-2 finding 1).
        t.bind_task("unit-2", "task-xyz")
        t.observe(_task_created("task-xyz", "Implement widget"))
        t.observe(_task_completed("task-xyz", "Implement widget"))
        t.observe(_agent_started("agent-999", "unexpected-agent"))
        t.observe(_agent_stopped("agent-999", "unexpected-agent"))
        record = t.comparison_record()

        self.assertEqual(record["mismatches"]["planned_unexecuted"], ["unit-3"])
        # "unexpected-agent" carries a real agent_type name that matches
        # nothing planned — a confident mismatch.
        self.assertEqual(len(record["mismatches"]["unplanned_observed"]), 1)
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        self.assertEqual(len(record["observed"]), 3)

    def test_fifo_matches_multiple_planned_units_sharing_assigned_agent(self):
        # FIFO name-based matching remains valid for agent.* events —
        # agent_type is a real field (round-2 finding 1). This test used
        # to exercise the same mechanism via task.created, which is no
        # longer possible since task events carry no name at all.
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "feature-builder"),
        ]
        t = tracker.Tracker(graph)
        t.observe(_agent_started("agent-1", "feature-builder"))
        t.observe(_agent_started("agent-2", "feature-builder"))
        record = t.comparison_record()

        matched_ids = sorted(
            execution["unit_id"] for execution in record["observed"]
        )
        self.assertEqual(matched_ids, ["unit-a", "unit-b"])
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])

    def test_bind_task_matches_multiple_planned_units_to_distinct_tasks(self):
        # Coverage for the mechanism that actually replaces name-based FIFO
        # for task events: two independent bind_task() calls route two
        # task.created events to two distinct planned units.
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "feature-builder"),
        ]
        t = tracker.Tracker(graph)
        t.bind_task("unit-a", "task-1")
        t.bind_task("unit-b", "task-2")
        t.observe(_task_created("task-1", "Do A"))
        t.observe(_task_created("task-2", "Do B"))
        record = t.comparison_record()

        matched_ids = sorted(
            execution["unit_id"] for execution in record["observed"]
        )
        self.assertEqual(matched_ids, ["unit-a", "unit-b"])
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])

    def test_task_events_without_bind_or_marker_are_unbound_not_mismatched(self):
        # This is the exact false-mismatch scenario from round-2 finding 1:
        # a plain task.created/task.completed pair with the OFFICIAL field
        # set (no subagent_type, no name signal of any kind) must not be
        # asserted as a confident "unplanned" mismatch.
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "Implement widget"))
        t.observe(_task_completed("task-xyz", "Implement widget"))
        record = t.comparison_record()

        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        unbound = record["mismatches"]["unbound_observed"]
        self.assertEqual(len(unbound), 1)
        self.assertIsNone(unbound[0]["unit_id"])
        self.assertEqual(unbound[0]["correlation"], "unbound")
        self.assertEqual(unbound[0]["events"], ["task.created", "task.completed"])
        # all 3 planned units remain unexecuted — an unbound observation
        # must not silently consume any of them.
        self.assertEqual(
            sorted(record["mismatches"]["planned_unexecuted"]),
            ["unit-1", "unit-2", "unit-3"],
        )

    def test_non_orchestration_events_are_ignored(self):
        t = _fresh_tracker()
        result = t.observe(
            adapter.normalize_event(
                {
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "ls"},
                }
            )
        )
        self.assertIsNone(result)
        record = t.comparison_record()
        self.assertEqual(record["observed"], [])


# ---------------------------------------------------------------------------
# 3. 강등(degraded) 필드
# ---------------------------------------------------------------------------


class DegradationTest(unittest.TestCase):
    def test_degraded_starts_as_none(self):
        t = _fresh_tracker()
        self.assertIsNone(t.degraded)
        self.assertIsNone(t.comparison_record()["degraded"])

    def test_record_degradation_sets_reason_and_timestamp(self):
        t = _fresh_tracker()
        result = t.record_degradation("nested dispatch unsupported in this environment")
        self.assertEqual(
            result["reason"], "nested dispatch unsupported in this environment"
        )
        self.assertIn("recorded_at", result)
        self.assertEqual(t.degraded["reason"], result["reason"])
        self.assertEqual(t.comparison_record()["degraded"]["reason"], result["reason"])

    def test_record_degradation_rejects_empty_reason(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation("")

    def test_record_degradation_last_call_wins(self):
        t = _fresh_tracker()
        t.record_degradation("first reason")
        t.record_degradation("second reason")
        self.assertEqual(t.degraded["reason"], "second reason")


# ---------------------------------------------------------------------------
# 4. 입력 계약 위반
# ---------------------------------------------------------------------------


class InputContractTest(unittest.TestCase):
    def test_planned_unit_without_id_is_rejected(self):
        with self.assertRaises(tracker.TrackerError):
            tracker.Tracker([{"assigned_agent": "feature-builder"}])

    def test_duplicate_planned_unit_id_is_rejected(self):
        with self.assertRaises(tracker.TrackerError):
            tracker.Tracker(
                [
                    _planned_unit("dup", "feature-builder"),
                    _planned_unit("dup", "security-reviewer"),
                ]
            )

    def test_non_mapping_planned_unit_is_rejected(self):
        with self.assertRaises(tracker.TrackerError):
            tracker.Tracker(["not-a-mapping"])

    def test_observe_rejects_event_without_name(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.observe({"payload": {}})


# ---------------------------------------------------------------------------
# 5. 영속화 — 로컬 runtime state (spec §2.3)
# ---------------------------------------------------------------------------


class PersistenceTest(unittest.TestCase):
    def test_flush_without_project_root_stays_in_memory(self):
        t = _fresh_tracker(project_root=None)
        t.observe(_agent_started("agent-abc", "security-reviewer"))

        # `local.STATE_DIR_RELATIVE`(".rein/state")는 상대 경로라
        # `os.path.exists()` 는 프로세스의 현재 작업 디렉토리 기준으로
        # 해석한다. 이 저장소 루트를 cwd 로 두고 돌리면 세션 훅이 만든
        # 무관한 `.rein/state/` 가 이미 있어(gitignored — 있을 때도
        # 없을 때도 있다) flush 가 새로 만든 게 없어도 오탐 실패한다.
        # flush 를 격리된 임시 cwd 안에서 실행해 이 오염을 차단한다 —
        # 어떤 cwd 에서 테스트를 실행하든 결정론적이어야 한다.
        original_cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as isolated_cwd:
            os.chdir(isolated_cwd)
            try:
                record = t.flush()
            finally:
                os.chdir(original_cwd)

            self.assertEqual(record["observed"][0]["unit_id"], "unit-1")
            # project_root 가 없으므로 격리된 cwd 안에도 상대 경로
            # 상태 디렉토리가 새로 생기지 않는다.
            self.assertFalse(
                os.path.exists(
                    os.path.join(isolated_cwd, local.STATE_DIR_RELATIVE)
                )
            )

    def test_flush_with_project_root_appends_jsonl_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.observe(_agent_started("agent-abc", "security-reviewer"))
            t.flush()
            t.observe(_agent_stopped("agent-abc", "security-reviewer"))
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            self.assertTrue(os.path.isfile(log_path))
            with open(log_path, "r", encoding="utf-8") as handle:
                lines = [line for line in handle if line.strip()]
            self.assertEqual(len(lines), 2)
            first_record = json.loads(lines[0])
            second_record = json.loads(lines[1])
            self.assertEqual(len(first_record["observed"][0]["events"]), 1)
            self.assertEqual(len(second_record["observed"][0]["events"]), 2)

    @unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약")
    def test_flush_creates_file_with_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.flush()
            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            mode = stat.S_IMODE(os.stat(log_path).st_mode)
            self.assertEqual(mode, 0o600)


# ---------------------------------------------------------------------------
# 5b. Round-5 HIGH — degradation reason/detail must be masked (repo's
#     existing masking SSOT, rein.shadow.masking) and length-capped at the
#     PERSISTENCE boundary (flush()'s JSONL write) before being written to
#     disk. dispatch_env's exception text (str(exc)) can carry a
#     token-shaped string verbatim; the repo security rule forbids
#     sensitive data in logs.
# ---------------------------------------------------------------------------


class DegradationPersistenceMaskingTest(unittest.TestCase):
    _TOKEN_SHAPED_DETAIL = (
        "nested dispatch raised: Authorization: Bearer "
        "sk-live-abcdef1234567890ABCDEF"
    )

    def test_masked_form_persisted_not_original_in_jsonl_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": self._TOKEN_SHAPED_DETAIL,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)
            persisted_detail = persisted["degraded"]["detail"]

            self.assertNotIn("sk-live-abcdef1234567890ABCDEF", persisted_detail)
            self.assertNotIn(self._TOKEN_SHAPED_DETAIL, persisted_detail)
            # matches the masking SSOT's actual replacement token, not a
            # guessed placeholder — proves the real SSOT ran, not a stub.
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, persisted_detail)

    def test_in_memory_returned_record_stays_unmasked(self):
        # The masking boundary is the FILE write specifically — the
        # in-memory value record_degradation()/flush() return to the
        # caller is not "a log" and must not be silently mutated.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            recorded = t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": self._TOKEN_SHAPED_DETAIL,
                }
            )
            self.assertEqual(recorded["detail"], self._TOKEN_SHAPED_DETAIL)

            returned = t.flush()
            self.assertEqual(
                returned["degraded"]["detail"], self._TOKEN_SHAPED_DETAIL
            )
            self.assertEqual(t.degraded["detail"], self._TOKEN_SHAPED_DETAIL)

    def test_reason_field_is_also_masked(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                "leaked token in reason: Authorization: Bearer sk-abc123XYZ"
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_reason = json.loads(line)["degraded"]["reason"]
            self.assertNotIn("sk-abc123XYZ", persisted_reason)

    def test_length_cap_applied_to_persisted_detail(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            huge_detail = "x" * (tracker._PERSISTED_STRING_MAX_CHARS + 3000)
            t.record_degradation(
                {"reason": "observed_dispatch_failure", "detail": huge_detail}
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_detail = json.loads(line)["degraded"]["detail"]

            # round-6 finding 2: the cap must be INCLUSIVE of the
            # truncation marker (14 chars) -- the pre-fix behavior sliced
            # to _PERSISTED_STRING_MAX_CHARS and then appended the
            # marker on top, persisting up to 2048+14=2062 chars. The
            # total must never exceed the cap itself.
            self.assertLessEqual(
                len(persisted_detail), tracker._PERSISTED_STRING_MAX_CHARS
            )
            self.assertEqual(
                len(persisted_detail), tracker._PERSISTED_STRING_MAX_CHARS
            )
            self.assertTrue(
                persisted_detail.endswith(
                    tracker._PERSISTED_STRING_TRUNCATION_MARKER
                )
            )
            # the in-memory value remains full-length and untruncated.
            self.assertEqual(len(t.degraded["detail"]), len(huge_detail))

    def test_masking_runs_before_truncation_not_after(self):
        # If truncation ran first, a token near the cut boundary could be
        # sliced mid-secret and survive masking as a broken fragment.
        # Build a detail where the sensitive substring straddles where a
        # naive truncate-then-mask would cut.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            padding = "x" * (tracker._PERSISTED_STRING_MAX_CHARS - 20)
            detail = padding + " Authorization: Bearer sk-boundary-secret-999"
            t.record_degradation(
                {"reason": "observed_dispatch_failure", "detail": detail}
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_detail = json.loads(line)["degraded"]["detail"]
            self.assertNotIn("sk-boundary-secret-999", persisted_detail)

    def test_extra_mapping_key_with_token_shaped_value_is_masked(self):
        # round-6 finding 3: record_degradation() preserves ANY extra key
        # from the caller's Mapping (only "reason" itself is validated) --
        # round-5's fix only masked the two KNOWN keys (reason/detail),
        # so a field like "context" leaked a token verbatim.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": "Authorization: Bearer sk-extra-context-000",
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)["degraded"]

            self.assertNotIn("sk-extra-context-000", persisted["context"])
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, persisted["context"])
            # known fields still masked too (no regression).
            self.assertEqual(persisted["detail"], "ok")

    def test_extra_key_length_cap_also_applied(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": "x" * 5000,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_context = json.loads(line)["degraded"]["context"]
            self.assertEqual(
                len(persisted_context), tracker._PERSISTED_STRING_MAX_CHARS
            )

    def test_non_string_extra_values_pass_through_unmasked(self):
        # Non-string scalars (state/mode-like fields) are not string
        # secrets and must not be mangled by masking/truncation.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "retry_count": 3,
                    "recoverable": True,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)["degraded"]
            self.assertEqual(persisted["retry_count"], 3)
            self.assertIs(persisted["recoverable"], True)

    def test_nested_dict_value_is_masked_recursively(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": {
                        "nested_secret": "Authorization: Bearer sk-nested-000"
                    },
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)["degraded"]
            self.assertNotIn(
                "sk-nested-000", persisted["context"]["nested_secret"]
            )

    def test_list_of_strings_value_is_masked_recursively(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": [
                        "plain entry",
                        "Authorization: Bearer sk-list-entry-000",
                    ],
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_context = json.loads(line)["degraded"]["context"]
            self.assertEqual(persisted_context[0], "plain entry")
            self.assertNotIn("sk-list-entry-000", persisted_context[1])

    @staticmethod
    def _nest(levels, leaf):
        """`leaf` 를 `{"L1": {"L2": ... {"L<levels>": leaf}}}` 형태로
        `levels` 단계 감싼다."""
        value = leaf
        for i in range(levels, 0, -1):
            value = {"L{}".format(i): value}
        return value

    # round-9/10 HIGH/MEDIUM note: `flush()` now routes the ENTIRE
    # persistable record through `_masked_persistable_value()`, and
    # `record["degraded"]` is itself a field of that record -- so TWO
    # levels of the recursion budget are consumed (one for `record`, one
    # for `degraded`) before ever reaching a field *within* degraded
    # (e.g. "context"). `_PERSISTED_VALUE_MAX_DEPTH` was bumped 6->7 in
    # round-10 (on top of round-9's 5->6 bump) specifically to keep this
    # field-relative budget identical across all three rounds -- but that
    # means the budget available to nesting *underneath* a field inside
    # degraded is `_PERSISTED_VALUE_MAX_DEPTH - 2`, not `- 1` (round-9)
    # and not the raw constant. These two boundary tests build nesting
    # relative to that field-level budget.
    _FIELD_RELATIVE_MAX_DEPTH = tracker._PERSISTED_VALUE_MAX_DEPTH - 2

    def test_secret_at_exactly_the_depth_limit_is_masked_normally(self):
        # round-7 HIGH boundary test — nesting depth exactly equal to the
        # field-relative budget must still be masked normally (not
        # replaced by the depth-limit placeholder). The string check runs
        # before the depth check regardless of remaining depth, so a leaf
        # landing exactly at the limit is still reached and masked.
        secret = "Authorization: Bearer sk-at-limit-secret-000"
        nested = self._nest(self._FIELD_RELATIVE_MAX_DEPTH, secret)
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": nested,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)["degraded"]["context"]

            value = persisted
            for i in range(1, self._FIELD_RELATIVE_MAX_DEPTH + 1):
                value = value["L{}".format(i)]
            self.assertNotIn("sk-at-limit-secret-000", value)
            # masked normally (via the real masking SSOT), NOT collapsed
            # to the depth-limit placeholder -- this nesting is still
            # within the walkable budget.
            self.assertNotEqual(value, tracker._PERSISTED_DEPTH_LIMIT_MARKER)
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, value)

    def test_secret_beyond_depth_limit_yields_zero_original_content(self):
        # round-7 HIGH reproduction: a secret nested ONE level past the
        # (field-relative) limit previously survived verbatim -- the
        # container at the exhausted-depth boundary was returned raw, so
        # its string leaf was never even visited by the masking walk.
        secret = "Authorization: Bearer sk-over-limit-secret-000"
        nested = self._nest(self._FIELD_RELATIVE_MAX_DEPTH + 1, secret)
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": nested,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            raw_line = line
            persisted = json.loads(line)["degraded"]

            # zero original content anywhere in the persisted JSONL line
            # -- not just "not in the expected nested slot".
            self.assertNotIn("sk-over-limit-secret-000", raw_line)
            self.assertNotIn("sk-over-limit-secret-000", json.dumps(persisted))

            # the over-depth subtree was replaced by the fixed
            # placeholder marker, reachable at the depth boundary (one
            # fewer unwrap than the nest count -- the LAST wrapper dict
            # is the one that gets swallowed into the placeholder).
            value = persisted["context"]
            for i in range(1, self._FIELD_RELATIVE_MAX_DEPTH + 1):
                value = value["L{}".format(i)]
            self.assertEqual(value, tracker._PERSISTED_DEPTH_LIMIT_MARKER)

    def test_six_level_nested_bearer_token_reproduction(self):
        # Exact reproduction phrasing from the round-7 finding: "a secret
        # nested deeper than 5 levels persists in plaintext (reproduced
        # with a 6-level nested Bearer token)".
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": {
                        "L1": {
                            "L2": {
                                "L3": {
                                    "L4": {
                                        "L5": {
                                            "L6": (
                                                "Authorization: Bearer "
                                                "sk-six-level-000"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    },
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertNotIn("sk-six-level-000", line)
            self.assertIn(tracker._PERSISTED_DEPTH_LIMIT_MARKER, line)

    def test_placeholder_never_contains_original_content_even_partially(self):
        # The placeholder must be a fixed constant, never derived from or
        # concatenated with the original data (e.g. no "first N chars of
        # the original" shortcut that could still leak a prefix).
        secret_fragment = "sk-partial-leak-check"
        nested = self._nest(
            tracker._PERSISTED_VALUE_MAX_DEPTH + 2,
            "Bearer " + secret_fragment + "-rest-of-token",
        )
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": nested,
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertNotIn(secret_fragment, line)
            self.assertEqual(
                line.count(tracker._PERSISTED_DEPTH_LIMIT_MARKER), 1
            )

    def test_credential_shaped_mapping_key_is_masked(self):
        # round-8 HIGH (a) reproduction: the recursive masking walker
        # masked Mapping VALUES but preserved KEYS raw. A credential-
        # shaped key must be masked exactly like a credential-shaped
        # value would be.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": {"Bearer raw-secret-token": "safe"},
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()

            self.assertNotIn("raw-secret-token", line)
            persisted_context = json.loads(line)["degraded"]["context"]
            keys = list(persisted_context.keys())
            self.assertEqual(len(keys), 1)
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, keys[0])
            # the value itself is untouched (it wasn't sensitive).
            self.assertEqual(persisted_context[keys[0]], "safe")

    def test_top_level_credential_shaped_key_is_masked(self):
        # round-9 HIGH reproduction: round-8's fix masked keys nested
        # UNDER a value (e.g. under "context"), but _masked_degradation_
        # fields() only ever applied the recursive walker to top-level
        # VALUES -- a credential-shaped key appearing at the TOP level of
        # the Mapping passed to record_degradation() itself was never
        # touched at all and persisted raw.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "Bearer raw-top-secret-token": "safe",
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()

            self.assertNotIn("raw-top-secret-token", line)
            persisted_degraded = json.loads(line)["degraded"]
            # the known fields (reason/detail) must be entirely
            # unaffected -- only the extra top-level key changed.
            self.assertEqual(
                persisted_degraded["reason"], "observed_dispatch_failure"
            )
            self.assertEqual(persisted_degraded["detail"], "ok")
            extra_keys = [
                k
                for k in persisted_degraded
                if k not in ("reason", "detail", "recorded_at")
            ]
            self.assertEqual(len(extra_keys), 1)
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, extra_keys[0])
            self.assertEqual(persisted_degraded[extra_keys[0]], "safe")

            # in-memory returned value stays raw -- masking is a
            # persistence-boundary-only concern (established convention
            # since round-5).
            self.assertIn("Bearer raw-top-secret-token", t.degraded)

    def test_non_str_mapping_keys_pass_through_unmasked(self):
        # int/bool keys cannot hold a hidden secret string -- they must
        # not be mangled by the key-masking pass. Uses homogeneous
        # (mutually comparable) int-like keys deliberately -- mixing
        # incomparable key types (e.g. int with None) is a separate
        # concern covered by test_mixed_incomparable_key_types_rejected_
        # at_record_time below.
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": {1: "a", 2: "b"},
                }
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted_context = json.loads(line)["degraded"]["context"]
            # Assert the surviving values are exactly what plain
            # json.dumps would have produced (JSON always stringifies
            # int keys), proving no masking occurred on these int keys.
            expected = json.loads(json.dumps({1: "a", 2: "b"}))
            self.assertEqual(persisted_context, expected)

    def test_mixed_incomparable_key_types_rejected_at_record_time(self):
        # This is the exact gap round-8's own regression test surfaced:
        # a dict with mutually incomparable key types (int mixed with
        # None) is plain-serializable (json.dumps() alone succeeds) but
        # still raises TypeError under flush()'s json.dumps(...,
        # sort_keys=True) call specifically. The record_degradation()
        # validation must reproduce flush()'s exact serialization call
        # (including sort_keys=True) so this failure mode is ALSO caught
        # at record time -- not just plain non-serializable values.
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation(
                {
                    "reason": "observed_dispatch_failure",
                    "detail": "ok",
                    "context": {1: "a", None: "c"},
                }
            )

    def test_non_json_serializable_value_rejected_at_record_time(self):
        # round-8 HIGH (b) reproduction: a non-serializable value (e.g.
        # object()) was previously accepted silently at record_degradation()
        # time and only exploded with a raw TypeError inside flush().
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation(
                {"reason": "observed_dispatch_failure", "detail": object()}
            )

    def test_non_json_serializable_value_error_is_tracker_error_not_type_error(
        self,
    ):
        t = _fresh_tracker()
        try:
            t.record_degradation(
                {"reason": "observed_dispatch_failure", "context": object()}
            )
            self.fail("expected TrackerError")
        except TypeError:
            self.fail(
                "a raw TypeError leaked out of record_degradation() -- "
                "must be the module's established TrackerError"
            )
        except tracker.TrackerError:
            pass

    def test_flush_unaffected_after_rejected_record_degradation(self):
        # The rejection must happen at record_degradation() -- flush()
        # must remain completely unaffected (no degradation was ever
        # actually recorded, so nothing to persist).
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            with self.assertRaises(tracker.TrackerError):
                t.record_degradation(
                    {"reason": "observed_dispatch_failure", "detail": object()}
                )
            self.assertIsNone(t.degraded)

            record = t.flush()  # must not raise
            self.assertIsNone(record["degraded"])

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertIsNone(json.loads(line)["degraded"])

    def test_non_json_serializable_top_level_reason_str_still_works(self):
        # Regression guard -- the plain-str calling convention (no
        # Mapping at all) is trivially always JSON-safe and must be
        # completely unaffected by the new validation.
        t = _fresh_tracker()
        result = t.record_degradation("plain string reason")
        self.assertEqual(result["reason"], "plain string reason")

    def test_no_degraded_field_flush_is_unaffected(self):
        # Regression guard — flush() with no degradation recorded must
        # not raise or alter behavior (degraded stays None throughout).
        with tempfile.TemporaryDirectory() as tmp:
            t = _fresh_tracker(project_root=tmp)
            t.observe(_agent_started("agent-abc", "security-reviewer"))
            record = t.flush()
            self.assertIsNone(record["degraded"])

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertIsNone(json.loads(line)["degraded"])


# ---------------------------------------------------------------------------
# 5c. Round-10 MEDIUM — flush() must mask the ENTIRE persistable record,
#     not just record["degraded"]. Planned WorkUnit fields (objective/
#     expected_output) are free text and can carry a token-shaped string
#     by accident; observed execution fields (assigned_agent/task_key/
#     agent_key) were also written raw. "Mask liberally when in doubt."
# ---------------------------------------------------------------------------


class PersistableRecordMaskingTest(unittest.TestCase):
    def test_token_shaped_planned_objective_is_masked_in_persisted_line(self):
        # round-10 MEDIUM reproduction: a planned WorkUnit's free-text
        # `objective` field containing a token-shaped string previously
        # persisted verbatim -- flush() only ever masked
        # record["degraded"], never record["planned"].
        graph = [
            _planned_unit(
                "unit-1",
                "feature-builder",
                objective=(
                    "Fix auth bug: Authorization: Bearer "
                    "sk-planned-objective-secret-000"
                ),
            )
        ]
        with tempfile.TemporaryDirectory() as tmp:
            t = tracker.Tracker(graph, project_root=tmp)
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()

            self.assertNotIn("sk-planned-objective-secret-000", line)
            persisted_unit = json.loads(line)["planned"][0]
            from rein.shadow import masking as masking_module

            self.assertIn(masking_module.MASK_TOKEN, persisted_unit["objective"])

    def test_token_shaped_expected_output_is_masked_in_persisted_line(self):
        graph = [
            _planned_unit(
                "unit-1",
                "feature-builder",
                expected_output=(
                    "Authorization: Bearer sk-expected-output-secret-000"
                ),
            )
        ]
        with tempfile.TemporaryDirectory() as tmp:
            t = tracker.Tracker(graph, project_root=tmp)
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertNotIn("sk-expected-output-secret-000", line)

    def test_token_shaped_observed_field_is_masked(self):
        # observed execution records (assigned_agent/task_key/agent_key)
        # were also written raw pre-fix -- exercise via an agent name
        # containing a token-shaped string (assigned_agent is sourced
        # from the observed hook payload, not from planned WorkUnit data,
        # so this covers the "observed" subtree independently of
        # "planned").
        graph = [_planned_unit("unit-1", "Bearer raw-agent-name-secret-000")]
        with tempfile.TemporaryDirectory() as tmp:
            t = tracker.Tracker(graph, project_root=tmp)
            t.observe(
                _agent_started("agent-1", "Bearer raw-agent-name-secret-000")
            )
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            self.assertNotIn("raw-agent-name-secret-000", line)

    def test_normal_planned_and_observed_fields_persist_unchanged(self):
        # Sanity test: ordinary id/status/mode/assigned_agent values do
        # not match any masking rule (pattern-based -- not a blanket
        # string transform) and must survive byte-for-byte.
        graph = [
            _planned_unit(
                "unit-1",
                "feature-builder",
                objective="Implement the widget cache layer",
                expected_output="Cache hit rate improves by 20%",
                mode="edit_only",
            )
        ]
        with tempfile.TemporaryDirectory() as tmp:
            t = tracker.Tracker(graph, project_root=tmp)
            t.observe(_agent_started("agent-abc", "feature-builder"))
            t.observe(_agent_stopped("agent-abc", "feature-builder"))
            t.flush()

            log_path = os.path.join(
                tmp, local.STATE_DIR_RELATIVE, tracker.TRACKER_LOG_FILENAME
            )
            with open(log_path, "r", encoding="utf-8") as handle:
                line = handle.readline()
            persisted = json.loads(line)

            unit = persisted["planned"][0]
            self.assertEqual(unit["id"], "unit-1")
            self.assertEqual(unit["status"], "pending")
            self.assertEqual(unit["mode"], "edit_only")
            self.assertEqual(unit["assigned_agent"], "feature-builder")
            self.assertEqual(
                unit["objective"], "Implement the widget cache layer"
            )
            self.assertEqual(
                unit["expected_output"], "Cache hit rate improves by 20%"
            )

            execution = persisted["observed"][0]
            self.assertEqual(execution["unit_id"], "unit-1")
            self.assertEqual(execution["assigned_agent"], "feature-builder")
            self.assertEqual(execution["agent_key"], "agent-abc")
            self.assertTrue(execution["started"])
            self.assertTrue(execution["stopped"])
            self.assertEqual(
                execution["events"], ["agent.started", "agent.stopped"]
            )

    def test_in_memory_returned_record_stays_fully_unmasked(self):
        # The persistence-boundary-only convention (established since
        # round-5) still applies to the whole-record masking -- flush()'s
        # in-memory return value must remain completely raw.
        graph = [
            _planned_unit(
                "unit-1",
                "feature-builder",
                objective="Authorization: Bearer sk-in-memory-check-000",
            )
        ]
        with tempfile.TemporaryDirectory() as tmp:
            t = tracker.Tracker(graph, project_root=tmp)
            returned = t.flush()
            self.assertEqual(
                returned["planned"][0]["objective"],
                "Authorization: Bearer sk-in-memory-check-000",
            )


# ---------------------------------------------------------------------------
# 6. record_degradation() accepts str OR a dispatch_env-shaped Mapping
#    (finding 1 — composability with DispatchEnvironment(recorder=...))
# ---------------------------------------------------------------------------


class RecordDegradationMappingContractTest(unittest.TestCase):
    """`record_degradation` must accept the exact record shape
    `dispatch_env.DispatchEnvironment._degrade()` builds
    (`{"reason":..., "detail":..., "state":..., "mode":..., "notice":...}`)
    so `DispatchEnvironment(recorder=tracker.record_degradation)` composes
    without raising TrackerError (finding 1)."""

    def test_accepts_mapping_with_reason_key(self):
        t = _fresh_tracker()
        result = t.record_degradation(
            {
                "reason": "probe_incapable",
                "detail": "capability probe reported incapable",
                "state": "incapable",
                "mode": "single_worker",
                "notice": "단일 워커로 전환합니다",
            }
        )
        self.assertEqual(result["reason"], "probe_incapable")
        self.assertEqual(result["detail"], "capability probe reported incapable")
        self.assertEqual(result["mode"], "single_worker")
        self.assertIn("recorded_at", result)
        self.assertEqual(t.degraded["reason"], "probe_incapable")
        self.assertEqual(
            t.comparison_record()["degraded"]["reason"], "probe_incapable"
        )

    def test_still_accepts_plain_str_reason(self):
        # backward-compat — the original contract (plain str) keeps working.
        t = _fresh_tracker()
        result = t.record_degradation("nested dispatch unsupported")
        self.assertEqual(result["reason"], "nested dispatch unsupported")
        self.assertIn("recorded_at", result)

    def test_rejects_mapping_without_reason_key(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation({"detail": "no reason key here"})

    def test_rejects_mapping_with_empty_reason_value(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation({"reason": ""})

    def test_rejects_non_str_non_mapping(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.record_degradation(123)

    def test_last_call_wins_still_holds_for_mapping_input(self):
        t = _fresh_tracker()
        t.record_degradation("first reason")
        t.record_degradation({"reason": "second reason", "detail": "d"})
        self.assertEqual(t.degraded["reason"], "second reason")
        self.assertEqual(t.degraded["detail"], "d")


# ---------------------------------------------------------------------------
# 7a. Explicit WorkUnit-id binding contract for task events (finding 1b,
#     round-2 review) — task.created/task.completed carry no name field
#     at all (round-2 finding 1), so the original finding-3 fix ("attach
#     a same-name event across families instead of double-consuming a
#     planned unit") can never fire for task events in practice: they
#     never have a name to match with. bind_task() and the [unit:<id>]
#     marker are the real correlation paths for the task family.
# ---------------------------------------------------------------------------


class BindTaskApiTest(unittest.TestCase):
    """`Tracker.bind_task()` — public API for the prompt layer (finding 1b-i)."""

    def test_bind_task_reserves_unit_out_of_fifo_pool_immediately(self):
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "feature-builder"),
        ]
        t = tracker.Tracker(graph)
        t.bind_task("unit-b", "task-1")
        # unit-b is reserved — a plain agent.* FIFO match must now only
        # ever see unit-a (unit-b is no longer in the unclaimed pool).
        t.observe(_agent_started("agent-1", "feature-builder"))
        record = t.comparison_record()
        matched = [e for e in record["observed"] if e["unit_id"] == "unit-a"]
        self.assertEqual(len(matched), 1)

    def test_bind_task_then_observed_event_correlates_with_bound_marking(self):
        t = _fresh_tracker()
        t.bind_task("unit-2", "task-xyz")
        t.observe(_task_created("task-xyz", "Implement widget"))
        record = t.comparison_record()

        matched = [e for e in record["observed"] if e["unit_id"] == "unit-2"]
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0]["correlation"], "bound")

    def test_bind_task_rejects_unknown_unit_id(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.bind_task("no-such-unit", "task-xyz")

    def test_bind_task_rejects_empty_task_key(self):
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.bind_task("unit-1", "")

    def test_bind_task_rejects_duplicate_binding_of_same_task_key(self):
        t = _fresh_tracker()
        t.bind_task("unit-1", "task-xyz")
        with self.assertRaises(tracker.TrackerError):
            t.bind_task("unit-2", "task-xyz")


class UnitMarkerExtractionTest(unittest.TestCase):
    """`[unit:<id>]` marker in `task_subject` (finding 1b-ii) — a
    bind_task()-free way to correlate a task event to a planned unit."""

    def test_marker_in_task_subject_correlates_without_explicit_bind(self):
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "[unit:unit-2] Implement widget"))
        record = t.comparison_record()

        matched = [e for e in record["observed"] if e["unit_id"] == "unit-2"]
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0]["correlation"], "unit-marker")

    def test_marker_referencing_already_claimed_unit_is_ignored(self):
        # unit-2 is already claimed via bind_task() before the marker-
        # tagged task arrives — the marker must not double-claim it.
        t = _fresh_tracker()
        t.bind_task("unit-2", "task-other")
        t.observe(_task_created("task-xyz", "[unit:unit-2] Implement widget"))
        record = t.comparison_record()

        matched = [e for e in record["observed"] if e["unit_id"] == "unit-2"]
        self.assertEqual(len(matched), 0)
        # falls through to unbound (task events have no other name signal)
        unmatched = [e for e in record["observed"] if e["unit_id"] is None]
        self.assertEqual(len(unmatched), 1)
        self.assertEqual(unmatched[0]["correlation"], "unbound")

    def test_marker_referencing_unknown_unit_id_is_ignored(self):
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "[unit:no-such-unit] Implement widget"))
        record = t.comparison_record()

        self.assertEqual(record["mismatches"]["unbound_observed"][0]["correlation"], "unbound")

    def test_task_subject_without_marker_has_no_effect(self):
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "Implement widget (plain subject)"))
        record = t.comparison_record()

        self.assertEqual(record["observed"][0]["correlation"], "unbound")
        self.assertIsNone(record["observed"][0]["unit_id"])


class UnboundTaskMarkingTest(unittest.TestCase):
    """Bound task events correlate to their unit; unbound task events are
    marked explicitly rather than asserted as confident mismatches
    (finding 1b)."""

    def test_teammate_name_is_never_used_as_assigned_agent(self):
        # finding 1c — teammate_name is the task's creator, not its
        # assignee. Even when teammate_name happens to equal a planned
        # unit's assigned_agent name, that must NOT cause a match.
        t = _fresh_tracker()  # unit-2's assigned_agent == "feature-builder"
        t.observe(
            _task_created(
                "task-xyz", "Implement widget", teammate_name="feature-builder"
            )
        )
        record = t.comparison_record()

        self.assertIsNone(record["observed"][0]["unit_id"])
        self.assertEqual(record["observed"][0]["correlation"], "unbound")
        # teammate_name == "feature-builder" happens to equal unit-2's
        # assigned_agent, but must NOT cause a match — unit-2 stays
        # unexecuted.
        self.assertIn("unit-2", record["mismatches"]["planned_unexecuted"])


# ---------------------------------------------------------------------------
# 7b. Round-3 structural contract — unit-keyed execution merge. The task
#     channel (bind_task()/marker) and the agent channel (assigned_agent
#     name) must MERGE into a single execution once they resolve to the
#     same unit, regardless of arrival order (`_attach_by_name()`, which
#     round-2 kept as unreachable-but-harmless dead code, is retired —
#     this new unit-keyed design replaces it exactly).
# ---------------------------------------------------------------------------


class UnitKeyedMergeTest(unittest.TestCase):
    """Reproduce-first regression tests for both required arrival orders
    (round-3 point 2). Each must yield exactly ONE execution, the unit
    consumed exactly once, zero false unplanned_observed entries, zero
    hidden duplicates."""

    def test_order_a_bind_then_task_created_then_agent_started(self):
        # (a) bind_task -> task.created -> agent.started
        graph = [_planned_unit("unit-x", "feature-builder")]
        t = tracker.Tracker(graph)
        t.bind_task("unit-x", "task-1")
        t.observe(_task_created("task-1", "Implement widget"))
        t.observe(_agent_started("agent-1", "feature-builder"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-x")
        self.assertEqual(execution["task_key"], "task-1")
        self.assertEqual(execution["agent_key"], "agent-1")
        self.assertEqual(
            execution["events"], ["task.created", "agent.started"]
        )
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])

    def test_order_b_agent_started_then_task_created_bound(self):
        # (b) agent.started -> task.created(bound) — bind_task() has
        # already reserved the unit (removed it from the FIFO pool)
        # before either event is observed; the agent event arrives first.
        graph = [_planned_unit("unit-y", "feature-builder")]
        t = tracker.Tracker(graph)
        t.bind_task("unit-y", "task-2")
        t.observe(_agent_started("agent-2", "feature-builder"))
        t.observe(_task_created("task-2", "Implement widget 2"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-y")
        self.assertEqual(execution["task_key"], "task-2")
        self.assertEqual(execution["agent_key"], "agent-2")
        self.assertEqual(
            execution["events"], ["agent.started", "task.created"]
        )
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])

    def test_merge_survives_full_lifecycle_both_channels_stopped(self):
        graph = [_planned_unit("unit-x", "feature-builder")]
        t = tracker.Tracker(graph)
        t.bind_task("unit-x", "task-1")
        t.observe(_task_created("task-1", "Implement widget"))
        t.observe(_agent_started("agent-1", "feature-builder"))
        t.observe(_agent_stopped("agent-1", "feature-builder"))
        t.observe(_task_completed("task-1", "Implement widget"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertTrue(execution["started"])
        self.assertTrue(execution["stopped"])
        self.assertEqual(
            execution["events"],
            ["task.created", "agent.started", "agent.stopped", "task.completed"],
        )

    def test_unrelated_free_unit_not_hijacked_by_bound_but_unrealized_unit(self):
        # Regression guard for the merge priority order: when TWO units
        # share the same assigned_agent name and only ONE of them is
        # bind_task()-reserved, an unrelated agent.started (not meant for
        # the bound task) must land on the genuinely free unit, not
        # hijack the reservation meant for a different logical task.
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "feature-builder"),
        ]
        t = tracker.Tracker(graph)
        t.bind_task("unit-b", "task-1")
        t.observe(_agent_started("agent-1", "feature-builder"))
        record = t.comparison_record()

        matched_a = [e for e in record["observed"] if e["unit_id"] == "unit-a"]
        self.assertEqual(len(matched_a), 1)
        self.assertIsNone(matched_a[0]["task_key"])
        # unit-b remains reserved and untouched, awaiting its own bound
        # task.created — not consumed by the unrelated agent event.
        self.assertIn("unit-b", record["mismatches"]["planned_unexecuted"])


class DuplicateBindingRejectionTest(unittest.TestCase):
    """Round-3 structural contract rule 3 — binding the SAME unit to two
    DIFFERENT task_keys is rejected explicitly (no silent overwrite);
    binding a unit already correlated via the agent channel merges
    instead of being rejected."""

    def test_binding_same_unit_to_different_task_key_is_rejected(self):
        t = _fresh_tracker()
        t.bind_task("unit-1", "task-a")
        with self.assertRaises(tracker.TrackerError):
            t.bind_task("unit-1", "task-b")

    def test_bind_after_agent_channel_correlation_merges_not_rejected(self):
        t = _fresh_tracker()
        # unit-1's assigned_agent == "security-reviewer" — FIFO-claims it.
        t.observe(_agent_started("agent-1", "security-reviewer"))
        # binding the SAME unit now must NOT raise — it merges per rule 1.
        t.bind_task("unit-1", "task-1")
        t.observe(_task_created("task-1", "Implement widget"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-1")
        self.assertEqual(execution["agent_key"], "agent-1")
        self.assertEqual(execution["task_key"], "task-1")


# ---------------------------------------------------------------------------
# 7c2. Round-4 HIGH — bind_task() must retroactively bind an
#      already-observed unbound task-channel execution. The documented
#      real-world flow fires the task-creation hook DURING the tool call,
#      so task.created is often observed before the prompt layer receives
#      the task id back and calls bind_task().
# ---------------------------------------------------------------------------


class RetroactiveBindTest(unittest.TestCase):
    """Reproduce-first: task.created -> bind_task -> {task.completed,
    agent.started} must resolve to ONE bound execution, not leave it
    stuck in the unbound bucket forever."""

    def test_task_created_then_bind_then_task_completed(self):
        # Reproduction of the exact round-4 scenario: before the fix this
        # yielded unit_id=None, correlation="unbound", unit-1 stuck in
        # planned_unexecuted.
        graph = [_planned_unit("unit-1", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-1", "Implement widget"))

        # sanity: BEFORE bind_task, this really is unbound (pins the
        # reproduction so the fix is provably doing something).
        pre_record = t.comparison_record()
        self.assertEqual(len(pre_record["mismatches"]["unbound_observed"]), 1)
        self.assertEqual(pre_record["mismatches"]["unbound_observed"][0]["correlation"], "unbound")

        t.bind_task("unit-1", "task-1")
        t.observe(_task_completed("task-1", "Implement widget"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-1")
        self.assertEqual(execution["correlation"], "bound")
        self.assertTrue(execution["started"])
        self.assertTrue(execution["stopped"])
        self.assertEqual(
            execution["events"], ["task.created", "task.completed"]
        )
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])

    def test_task_created_then_bind_then_agent_started(self):
        # Same real-world order, but the agent channel then merges into
        # the retroactively-bound execution (structural contract rule 1
        # still applies after retroactive binding).
        graph = [_planned_unit("unit-2", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-2", "Implement widget 2"))
        t.bind_task("unit-2", "task-2")
        t.observe(_agent_started("agent-2", "feature-builder"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-2")
        self.assertEqual(execution["task_key"], "task-2")
        self.assertEqual(execution["agent_key"], "agent-2")
        self.assertEqual(execution["assigned_agent"], "feature-builder")
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])

    def test_retroactive_bind_is_idempotent_when_unit_already_matches(self):
        # bind_task() called with the SAME unit that a [unit:<id>] marker
        # already resolved to (before the bind call) — must not raise,
        # must not duplicate.
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "[unit:unit-2] Implement widget"))
        t.bind_task("unit-2", "task-xyz")  # must not raise
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        self.assertEqual(record["observed"][0]["unit_id"], "unit-2")

    def test_retroactive_bind_rejects_conflicting_prior_marker_resolution(self):
        # The observed execution already resolved (via marker) to a
        # DIFFERENT unit than the one bind_task() now names — conflict,
        # must be rejected rather than silently overwritten.
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "feature-builder"),
        ]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-xyz", "[unit:unit-a] Implement widget"))
        with self.assertRaises(tracker.TrackerError):
            t.bind_task("unit-b", "task-xyz")

    def test_retroactive_bind_preserves_events_observed_before_binding(self):
        # Both task.created AND task.completed observed before bind_task()
        # -- the retroactive bind must still correctly mark the unit as
        # executed (not just "matched but not counted").
        t = _fresh_tracker()
        t.observe(_task_created("task-xyz", "Implement widget"))
        t.observe(_task_completed("task-xyz", "Implement widget"))
        t.bind_task("unit-2", "task-xyz")
        record = t.comparison_record()

        self.assertNotIn("unit-2", record["mismatches"]["planned_unexecuted"])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        matched = [e for e in record["observed"] if e["unit_id"] == "unit-2"]
        self.assertEqual(len(matched), 1)
        self.assertTrue(matched[0]["stopped"])


# ---------------------------------------------------------------------------
# 7c2b. Round-5 HIGH — retroactive bind_task() must MERGE with an EXISTING
#       agent-channel execution for the same unit, not create a second,
#       duplicate execution record. Reproduction: task.created(task-t) ->
#       agent.started(agent-a, resolves unit-u via name) ->
#       bind_task(unit-u, task-t) previously yielded TWO records for
#       unit-u (the retroactive path overwrote _executions_by_unit_id
#       without checking for the agent execution already registered
#       there).
# ---------------------------------------------------------------------------


class RetroactiveBindAgentChannelMergeTest(unittest.TestCase):
    def test_task_created_agent_started_then_bind_yields_one_execution(self):
        # Exact round-5 reproduction order.
        graph = [_planned_unit("unit-u", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-t", "Implement widget"))
        t.observe(_agent_started("agent-a", "feature-builder"))

        # sanity: BEFORE bind_task, this really is two separate records
        # (pins the reproduction so the fix is provably doing something).
        pre_record = t.comparison_record()
        self.assertEqual(len(pre_record["observed"]), 2)

        t.bind_task("unit-u", "task-t")
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-u")
        self.assertEqual(execution["task_key"], "task-t")
        self.assertEqual(execution["agent_key"], "agent-a")
        self.assertEqual(execution["assigned_agent"], "feature-builder")
        # round-6 finding 1: exact chronological order, not just set
        # membership -- task.created was observed before agent.started in
        # this test's arrival order, and the merge must preserve that.
        self.assertEqual(
            execution["events"], ["task.created", "agent.started"]
        )
        self.assertEqual(record["mismatches"]["unbound_observed"], [])
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["planned_unexecuted"], [])
        # the unit is counted as executed exactly once.
        self.assertNotIn("unit-u", record["mismatches"]["planned_unexecuted"])

    def test_stale_task_execution_removed_from_every_index(self):
        # White-box: after the merge, the discarded task-channel execution
        # must not be independently reachable via any lookup path.
        graph = [_planned_unit("unit-u", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-t", "Implement widget"))
        t.observe(_agent_started("agent-a", "feature-builder"))
        t.bind_task("unit-u", "task-t")

        self.assertEqual(len(t._executions), 1)
        self.assertIs(
            t._executions_by_key[("task", "task-t")],
            t._executions_by_key[("agent", "agent-a")],
        )
        self.assertIs(
            t._executions_by_key[("task", "task-t")],
            t._executions_by_unit_id["unit-u"],
        )

    def test_agent_started_task_created_then_bind_also_merges(self):
        # Reversed observation order of the two events (still both before
        # bind_task) -- same outcome.
        graph = [_planned_unit("unit-v", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_agent_started("agent-b", "feature-builder"))
        t.observe(_task_created("task-s", "Implement widget"))
        t.bind_task("unit-v", "task-s")
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-v")
        self.assertEqual(execution["task_key"], "task-s")
        self.assertEqual(execution["agent_key"], "agent-b")

    def test_three_way_shuffle_all_orderings_converge_to_one_execution(self):
        # Sanity check across all 6 permutations of {task.created,
        # agent.started, bind_task} -- every ordering must converge to
        # exactly one execution, the unit consumed exactly once.
        import itertools

        def run_order(order):
            graph = [_planned_unit("unit-u", "feature-builder")]
            tt = tracker.Tracker(graph)
            for action in order:
                if action == "task_created":
                    tt.observe(_task_created("task-t", "Implement widget"))
                elif action == "agent_started":
                    tt.observe(_agent_started("agent-a", "feature-builder"))
                elif action == "bind":
                    tt.bind_task("unit-u", "task-t")
            return tt.comparison_record()

        for order in itertools.permutations(
            ["task_created", "agent_started", "bind"]
        ):
            with self.subTest(order=order):
                record = run_order(order)
                self.assertEqual(len(record["observed"]), 1, msg=repr(order))
                execution = record["observed"][0]
                self.assertEqual(execution["unit_id"], "unit-u")
                self.assertEqual(execution["task_key"], "task-t")
                self.assertEqual(execution["agent_key"], "agent-a")
                self.assertEqual(
                    record["mismatches"]["unbound_observed"], [], msg=repr(order)
                )
                self.assertEqual(
                    record["mismatches"]["unplanned_observed"], [], msg=repr(order)
                )


# ---------------------------------------------------------------------------
# 7c2c. Round-6 HIGH — merge must preserve TRUE chronological event order
#       (a global observation ordinal), not the order in which the two
#       executions happened to be *created*. Reproduction: task.created ->
#       agent.started -> agent.stopped -> task.completed -> bind previously
#       persisted as task.created -> task.completed -> agent.started ->
#       agent.stopped (round-5's "creation-order concatenation" put ALL of
#       the earlier-created execution's events first, corrupting the
#       interleaving).
# ---------------------------------------------------------------------------


class MergeEventChronologyTest(unittest.TestCase):
    def test_interleaved_history_merges_in_exact_observed_order(self):
        graph = [_planned_unit("unit-u", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-t", "Implement widget"))
        t.observe(_agent_started("agent-a", "feature-builder"))
        t.observe(_agent_stopped("agent-a", "feature-builder"))
        t.observe(_task_completed("task-t", "Implement widget"))
        t.bind_task("unit-u", "task-t")
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        execution = record["observed"][0]
        self.assertEqual(execution["unit_id"], "unit-u")
        # Exact sequence -- NOT sorted()/set comparison. This is the
        # precise assertion the round-6 finding requires: a naive
        # "earlier-created execution's events all come first" merge would
        # produce ["task.created", "task.completed", "agent.started",
        # "agent.stopped"] here, silently reordering task.completed to
        # before agent.started/agent.stopped even though it was actually
        # observed last.
        self.assertEqual(
            execution["events"],
            [
                "task.created",
                "agent.started",
                "agent.stopped",
                "task.completed",
            ],
        )
        self.assertTrue(execution["started"])
        self.assertTrue(execution["stopped"])

    def test_reverse_channel_creation_order_still_merges_chronologically(self):
        # The agent channel is created FIRST this time (bind happens
        # later still), but task-channel events interleave in the middle
        # -- the merge must not assume "whichever execution object was
        # created first contributes its events first."
        graph = [_planned_unit("unit-u", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_agent_started("agent-a", "feature-builder"))
        t.observe(_task_created("task-t", "Implement widget"))
        t.observe(_task_completed("task-t", "Implement widget"))
        t.observe(_agent_stopped("agent-a", "feature-builder"))
        t.bind_task("unit-u", "task-t")
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        self.assertEqual(
            record["observed"][0]["events"],
            [
                "agent.started",
                "task.created",
                "task.completed",
                "agent.stopped",
            ],
        )

    def test_bind_in_the_middle_of_interleaved_history_still_chronological(self):
        # bind_task() fires the merge partway through the interleaved
        # history (not at the very end) -- events observed AFTER the
        # merge (through the single surviving execution) must still slot
        # in at the correct chronological position relative to the
        # pre-merge history.
        graph = [_planned_unit("unit-u", "feature-builder")]
        t = tracker.Tracker(graph)
        t.observe(_task_created("task-t", "Implement widget"))
        t.observe(_agent_started("agent-a", "feature-builder"))
        t.bind_task("unit-u", "task-t")  # merge happens here
        t.observe(_agent_stopped("agent-a", "feature-builder"))
        t.observe(_task_completed("task-t", "Implement widget"))
        record = t.comparison_record()

        self.assertEqual(len(record["observed"]), 1)
        self.assertEqual(
            record["observed"][0]["events"],
            [
                "task.created",
                "agent.started",
                "agent.stopped",
                "task.completed",
            ],
        )


# ---------------------------------------------------------------------------
# 7c3. Round-4 MEDIUM — channel-namespaced execution keys. A task_id and
#      an agent_id that collide as raw strings must never merge two
#      unrelated executions.
# ---------------------------------------------------------------------------


class ChannelKeyCollisionTest(unittest.TestCase):
    def test_task_id_and_agent_id_string_collision_do_not_merge(self):
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "security-reviewer"),
        ]
        t = tracker.Tracker(graph)
        t.bind_task("unit-a", "shared-id")
        t.observe(_task_created("shared-id", "Implement widget"))
        # An agent event whose agent_id happens to be the exact same
        # literal string as the task_id above — must NOT attach to the
        # task execution, must NOT lose its own agent_key/assigned_agent.
        t.observe(_agent_started("shared-id", "security-reviewer"))
        record = t.comparison_record()

        task_execution = [e for e in record["observed"] if e["unit_id"] == "unit-a"]
        self.assertEqual(len(task_execution), 1)
        self.assertEqual(task_execution[0]["task_key"], "shared-id")
        self.assertIsNone(task_execution[0]["agent_key"])

        agent_execution = [e for e in record["observed"] if e["unit_id"] == "unit-b"]
        self.assertEqual(len(agent_execution), 1)
        self.assertEqual(agent_execution[0]["agent_key"], "shared-id")
        self.assertIsNone(agent_execution[0]["task_key"])
        self.assertEqual(agent_execution[0]["assigned_agent"], "security-reviewer")

        self.assertEqual(len(record["observed"]), 2)
        self.assertEqual(record["mismatches"]["unplanned_observed"], [])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])

    def test_collision_reverse_order_agent_then_task(self):
        graph = [
            _planned_unit("unit-a", "feature-builder"),
            _planned_unit("unit-b", "security-reviewer"),
        ]
        t = tracker.Tracker(graph)
        t.observe(_agent_started("collide", "security-reviewer"))
        t.bind_task("unit-a", "collide")
        t.observe(_task_created("collide", "Implement widget"))
        record = t.comparison_record()

        task_execution = [e for e in record["observed"] if e["unit_id"] == "unit-a"]
        agent_execution = [e for e in record["observed"] if e["unit_id"] == "unit-b"]
        self.assertEqual(len(task_execution), 1)
        self.assertEqual(len(agent_execution), 1)
        self.assertEqual(task_execution[0]["agent_key"], None)
        self.assertEqual(agent_execution[0]["task_key"], None)
        self.assertEqual(len(record["observed"]), 2)


# ---------------------------------------------------------------------------
# 7c4. Round-4 MEDIUM — `event.get("payload") or {}` masked falsy
#      non-mapping payloads (False/0/[]/""/()) as an empty (valid)
#      mapping, bypassing the type check entirely.
# ---------------------------------------------------------------------------


class PayloadFalsyMaskingTest(unittest.TestCase):
    def test_falsy_non_mapping_payloads_are_rejected(self):
        t = _fresh_tracker()
        for bad_payload in (False, 0, 0.0, [], "", (), set()):
            with self.assertRaises(
                tracker.TrackerError, msg=repr(bad_payload)
            ):
                t.observe({"name": "agent.started", "payload": bad_payload})

    def test_truthy_non_mapping_payload_is_still_rejected(self):
        # Regression guard — this path already worked before the fix
        # (truthy values bypass `or {}`); confirm it still does.
        t = _fresh_tracker()
        with self.assertRaises(tracker.TrackerError):
            t.observe({"name": "agent.started", "payload": [1, 2, 3]})

    def test_none_payload_is_treated_as_empty_mapping(self):
        t = _fresh_tracker()
        result = t.observe({"name": "agent.started", "payload": None})
        self.assertIsNotNone(result)

    def test_missing_payload_key_is_treated_as_empty_mapping(self):
        t = _fresh_tracker()
        result = t.observe({"name": "task.created"})
        self.assertIsNotNone(result)
        self.assertEqual(result["correlation"], "unbound")

    def test_empty_dict_payload_still_works(self):
        t = _fresh_tracker()
        result = t.observe({"name": "agent.started", "payload": {}})
        self.assertIsNotNone(result)


# ---------------------------------------------------------------------------
# 7c. MEDIUM — adapter identity-field type validation + tracker defensive
#     instance-key handling (round-3 review).
# ---------------------------------------------------------------------------


class TrackerDefensiveInstanceKeyTest(unittest.TestCase):
    """Tracker must not crash if a malformed event (constructed directly,
    bypassing adapter.py) carries a non-str identity field — instance keys
    are used as dict keys internally, so a non-str value would otherwise
    raise TypeError: unhashable type."""

    def test_non_str_agent_id_does_not_crash_observe(self):
        t = _fresh_tracker()
        malformed = {
            "name": "agent.started",
            "tool": None,
            "payload": {"agent_id": ["bad"], "agent_type": "security-reviewer"},
        }
        result = t.observe(malformed)  # must not raise TypeError
        self.assertIsNotNone(result)
        self.assertEqual(result["assigned_agent"], "security-reviewer")

    def test_non_str_task_id_does_not_crash_observe(self):
        t = _fresh_tracker()
        malformed = {
            "name": "task.created",
            "tool": None,
            "payload": {"task_id": {"nested": True}, "task_subject": "x"},
        }
        result = t.observe(malformed)  # must not raise TypeError
        self.assertIsNotNone(result)
        self.assertEqual(result["correlation"], "unbound")

    def test_non_str_agent_type_is_treated_as_no_name_signal(self):
        t = _fresh_tracker()
        malformed = {
            "name": "agent.started",
            "tool": None,
            "payload": {"agent_id": "agent-1", "agent_type": 12345},
        }
        result = t.observe(malformed)
        self.assertIsNone(result["unit_id"])
        self.assertIsNone(result["assigned_agent"])


class AdapterIdentityFieldTypeValidationTest(unittest.TestCase):
    """adapter.py must not pass a non-str identity field through as a
    top-level key (finding: agent_id=["bad"] reaching tracker as a dict
    key crashes with TypeError: unhashable)."""

    def test_non_scalar_agent_id_is_dropped_entirely(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "SubagentStart"
        payload["agent_id"] = ["bad"]
        payload["agent_type"] = "security-reviewer"
        event = adapter.normalize_event(payload)

        self.assertNotIn("agent_id", event["payload"])
        self.assertNotIn("agent_id", event["payload"]["extras"])
        self.assertEqual(event["payload"]["agent_type"], "security-reviewer")

    def test_int_agent_id_is_dropped_from_top_level_but_falls_into_extras(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "SubagentStart"
        payload["agent_id"] = 12345
        payload["agent_type"] = "security-reviewer"
        event = adapter.normalize_event(payload)

        self.assertNotIn("agent_id", event["payload"])
        self.assertEqual(event["payload"]["extras"]["agent_id"], 12345)

    def test_empty_str_identity_field_is_dropped_from_top_level(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "SubagentStart"
        payload["agent_id"] = ""
        payload["agent_type"] = "security-reviewer"
        event = adapter.normalize_event(payload)

        self.assertNotIn("agent_id", event["payload"])

    def test_valid_str_identity_fields_are_unaffected(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "SubagentStart"
        payload["agent_id"] = "agent-abc"
        payload["agent_type"] = "security-reviewer"
        event = adapter.normalize_event(payload)

        self.assertEqual(event["payload"]["agent_id"], "agent-abc")
        self.assertEqual(event["payload"]["agent_type"], "security-reviewer")
        self.assertNotIn("agent_id", event["payload"]["extras"])

    def test_normalize_event_then_observe_does_not_crash_end_to_end(self):
        # Full pipeline: malformed real-world-shaped payload -> adapter ->
        # tracker.observe() -> no crash anywhere in the chain.
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "SubagentStart"
        payload["agent_id"] = ["bad"]
        payload["agent_type"] = "security-reviewer"
        event = adapter.normalize_event(payload)

        t = _fresh_tracker()
        result = t.observe(event)
        self.assertIsNotNone(result)
        self.assertEqual(result["assigned_agent"], "security-reviewer")


# ---------------------------------------------------------------------------
# 8. adapter agent-payload bounded 'extras' (finding 4)
# ---------------------------------------------------------------------------


class AgentPayloadExtrasBoundingTest(unittest.TestCase):
    """identity 필드는 top-level 유지, 나머지 비식별 필드는 bounded
    'extras' sub-dict 로 격리한다 — 상위 hook payload 의 임의 필드가
    kernel 이벤트 payload 를 무제한 오염시키지 않는다 (finding 4)."""

    def test_identity_fields_stay_top_level(self):
        event = _agent_started("agent-abc", "security-reviewer")
        self.assertEqual(event["payload"]["agent_id"], "agent-abc")
        self.assertEqual(event["payload"]["agent_type"], "security-reviewer")

    def test_task_identity_fields_stay_top_level(self):
        # Official field set (round-2 finding 1/1d) — task_subject is
        # identity-level here (not subagent_type, which never existed on
        # this event), because tracker.py's [unit:<id>] marker extraction
        # structurally depends on reading it un-truncated.
        event = _task_created(
            "task-xyz",
            "Implement widget",
            teammate_name="implementer",
        )
        self.assertEqual(event["payload"]["task_id"], "task-xyz")
        self.assertEqual(event["payload"]["task_subject"], "Implement widget")
        self.assertEqual(event["payload"]["teammate_name"], "implementer")
        self.assertNotIn("subagent_type", event["payload"])

    def test_non_identity_scalar_field_moves_to_extras(self):
        event = _task_created(
            "task-xyz", "Implement widget", task_description="implement widget"
        )
        self.assertNotIn("task_description", event["payload"])
        self.assertEqual(
            event["payload"]["extras"]["task_description"], "implement widget"
        )

    def test_extras_present_and_empty_when_no_non_identity_fields(self):
        event = _agent_started("agent-abc", "security-reviewer")
        self.assertEqual(event["payload"]["extras"], {})

    def test_task_subject_is_never_truncated_or_dropped_by_extras_bounding(self):
        # task_subject must survive un-truncated even when it is long or
        # there are 16+ other extra fields — the marker extraction
        # (finding 1b-ii) depends on this field being intact, and it is
        # NOT subject to the extras 256-char/16-key bounding since it is
        # a top-level identity field, not an extras entry.
        long_subject = "[unit:unit-2] " + ("x" * 400)
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "TaskCreated"
        payload["task_id"] = "task-1"
        payload["task_subject"] = long_subject
        for i in range(20):
            payload["field_{:02d}".format(i)] = i
        event = adapter.normalize_event(payload)
        self.assertEqual(event["payload"]["task_subject"], long_subject)
        self.assertNotIn("task_subject", event["payload"]["extras"])

    def test_extras_string_value_is_truncated_to_256_chars(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "TaskCreated"
        payload["task_id"] = "task-1"
        payload["task_subject"] = "Implement widget"
        payload["task_description"] = "x" * 500
        event = adapter.normalize_event(payload)
        self.assertEqual(len(event["payload"]["extras"]["task_description"]), 256)
        self.assertEqual(
            event["payload"]["extras"]["task_description"], "x" * 256
        )

    def test_extras_caps_at_16_keys_deterministic_sorted_order(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "TaskCreated"
        payload["task_id"] = "task-1"
        payload["task_subject"] = "Implement widget"
        for i in range(20):
            payload["field_{:02d}".format(i)] = i
        event = adapter.normalize_event(payload)
        extras = event["payload"]["extras"]
        self.assertEqual(len(extras), 16)
        self.assertEqual(list(extras.keys()), sorted(extras.keys()))
        expected_keys = sorted("field_{:02d}".format(i) for i in range(20))[:16]
        self.assertEqual(sorted(extras.keys()), expected_keys)

    def test_extras_drops_nested_structures_but_keeps_scalars(self):
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "TaskCreated"
        payload["task_id"] = "task-1"
        payload["task_subject"] = "Implement widget"
        payload["nested_dict"] = {"a": 1}
        payload["nested_list"] = [1, 2, 3]
        payload["plain_scalar"] = "kept"
        payload["none_scalar"] = None
        payload["bool_scalar"] = True
        payload["float_scalar"] = 1.5
        event = adapter.normalize_event(payload)
        extras = event["payload"]["extras"]
        self.assertNotIn("nested_dict", extras)
        self.assertNotIn("nested_list", extras)
        self.assertEqual(extras["plain_scalar"], "kept")
        self.assertIsNone(extras["none_scalar"])
        self.assertIs(extras["bool_scalar"], True)
        self.assertEqual(extras["float_scalar"], 1.5)

    def test_common_base_fields_never_appear_in_extras(self):
        event = _task_created("task-xyz", "Implement widget")
        for key in ("session_id", "transcript_path", "cwd", "permission_mode"):
            self.assertNotIn(key, event["payload"]["extras"])

    def test_subagent_type_and_tool_use_id_are_not_treated_as_identity(self):
        # Regression guard (finding 1d) — these two fields were removed
        # from the identity whitelist because they do not exist on any of
        # the 4 adopted hook payloads. If a payload happened to carry them
        # anyway (e.g. a future SDK change), they must fall through to the
        # generic bounded "extras" path like any other unrecognized field,
        # not be promoted to top-level.
        payload = dict(_COMMON_HOOK_BASE)
        payload["hook_event_name"] = "TaskCreated"
        payload["task_id"] = "task-1"
        payload["task_subject"] = "Implement widget"
        payload["subagent_type"] = "feature-builder"
        payload["tool_use_id"] = "tool-1"
        event = adapter.normalize_event(payload)
        self.assertNotIn("subagent_type", event["payload"])
        self.assertNotIn("tool_use_id", event["payload"])
        self.assertEqual(event["payload"]["extras"]["subagent_type"], "feature-builder")
        self.assertEqual(event["payload"]["extras"]["tool_use_id"], "tool-1")


# ---------------------------------------------------------------------------
# 9. JSONL persistence — single write() call (finding 5)
# ---------------------------------------------------------------------------


class SingleWriteAppendTest(unittest.TestCase):
    """flush() must issue exactly one handle.write() call per record —
    two separate write()s (JSON body, then "\\n") risk interleaving under
    concurrent hook processes appending to the same file (finding 5)."""

    def test_flush_appends_record_with_a_single_write_call(self):
        write_calls = []

        class _FakeHandle(object):
            def write(self, data):
                write_calls.append(data)

            def __enter__(self):
                return self

            def __exit__(self, *exc_info):
                return False

        class _FakeStateRoot(object):
            def __init__(self, project_root):
                pass

            def open_log(self, name):
                return _FakeHandle()

        original_root_cls = tracker.LocalStateRoot
        tracker.LocalStateRoot = _FakeStateRoot
        try:
            t = _fresh_tracker(project_root="/unused-fake-root")
            t.observe(_agent_started("agent-abc", "security-reviewer"))
            t.flush()
        finally:
            tracker.LocalStateRoot = original_root_cls

        self.assertEqual(len(write_calls), 1)
        self.assertTrue(write_calls[0].endswith("\n"))
        parsed = json.loads(write_calls[0])
        self.assertEqual(parsed["observed"][0]["unit_id"], "unit-1")


# ---------------------------------------------------------------------------
# 10. Real WorkGraph → to_planned_units() → Tracker (finding 2, integration)
# ---------------------------------------------------------------------------


@unittest.skipUnless(
    _TO_PLANNED_UNITS_AVAILABLE,
    "WorkGraph.to_planned_units() not present yet — sibling Task 5.1 wave "
    "worker's deliverable; re-run once it lands (F2 fix-review notes).",
)
class WorkGraphToPlannedUnitsIntegrationTest(unittest.TestCase):
    """실제 WorkGraph → to_planned_units() → Tracker 조립 (finding 2).

    Import-boundary exception: tracker.py itself never imports
    work_graph/work_unit (see its module docstring "Import 경계"). This
    integration test is exempt (F2 brief: cross-module import ban lifted
    for tests) precisely to prove the two sibling modules compose through
    the plain-dict contract, not through a shared class.
    """

    def test_real_work_graph_feeds_tracker_end_to_end(self):
        WorkUnit = work_unit_module.WorkUnit
        WorkGraph = work_graph_module.WorkGraph

        graph = WorkGraph(
            units=(
                WorkUnit(
                    id="unit-x",
                    objective="do x",
                    scope=("some/path.py",),
                    dependencies=(),
                    assigned_agent="feature-builder",
                    status="pending",
                    expected_output="x done",
                ),
                WorkUnit(
                    id="unit-y",
                    objective="do y",
                    scope=("some/other-path.py",),
                    dependencies=(),
                    assigned_agent="security-reviewer",
                    status="pending",
                    expected_output="y done",
                ),
            )
        )
        planned = graph.to_planned_units()
        self.assertIsInstance(planned, tuple)
        expected_fields = {
            "id",
            "objective",
            "scope",
            "dependencies",
            "assigned_agent",
            "status",
            "expected_output",
            "mode",
        }
        for unit in planned:
            self.assertIsInstance(unit, dict)
            self.assertEqual(set(unit.keys()), expected_fields)

        t = tracker.Tracker(planned)
        # task.created/task.completed carry no name field (round-2 finding
        # 1) — the prompt layer binds the task id it gets back from
        # TaskCreate to the WorkUnit it was dispatching (finding 1b-i).
        t.bind_task("unit-x", "task-x")
        t.observe(_task_created("task-x", "Implement widget"))
        t.observe(_task_completed("task-x", "Implement widget"))
        record = t.comparison_record()

        matched = [e for e in record["observed"] if e["unit_id"] == "unit-x"]
        self.assertEqual(len(matched), 1)
        self.assertTrue(matched[0]["stopped"])
        self.assertEqual(matched[0]["correlation"], "bound")
        self.assertEqual(record["mismatches"]["planned_unexecuted"], ["unit-y"])
        self.assertEqual(record["mismatches"]["unbound_observed"], [])


if __name__ == "__main__":
    unittest.main()
