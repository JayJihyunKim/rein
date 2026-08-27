"""plan Task 2.8 (p2-capture-v1-insert) — 훅 capture subject 회귀 테스트.

covers: shadow-capture-stores-masked-representation-never-raw-commands-from-capture-stage

배경 (code review MEDIUM, 2026-08-10): `post-edit-review-gate.sh`(v1 커밋
게이트, 2026-08-24 Phase 7 웨이브 3 편집 게이트 교대로 삭제됨 — 아래
"③-d 재조준" 절 참조) / `post-edit-spec-review-gate.sh` 는 편집 파일
목록을 `while IFS= read -r FILE_PATH; do ... done <<< "$FILE_PATHS"`
관용구로 순회한다. bash 의 here-string(`<<<`)은 끝에 개행을 보장하고,
루프를 끝내는 마지막(EOF) `read` 호출 — while 조건을 깨뜨려 루프를
종료시키는 그 호출 — 도 실패 *직전에* 변수에 빈 문자열을 대입한다. 이
관용구를 쓰는 훅들 중:
  - `post-edit-spec-review-gate.sh` 는 루프에 `break` 가 전혀 없다 →
    canonical spec 편집이든 아니든 EXIT trap 시점의 `$FILE_PATH` 는
    **항상** "" (100% 빈 subject 로 기록).
  - (구) `post-edit-review-gate.sh` 는 소스 확장자를 찾으면 `break`
    했다 → 소스 편집은 우연히 정상(루프 변수가 break 시점 값을 유지),
    비소스 편집만 끝까지 순회해 "" 로 덮인다(비소스 편집에서만 빈
    subject).

수정: `hooks/lib/shadow-capture.sh` 에 `shadow_capture_set_subject()`
setter + 전용 전역 `_SHADOW_SUBJECT` 를 추가하고, 훅이 경로가 확정되는
지점(루프 변수 수명과 무관한 시점)에서 그 값을 명시적으로 알려준다.
`_shadow_on_exit` 의 subject 우선순위는
`$COMMAND` → `$_SHADOW_SUBJECT` → `$FILE_PATH` 순.

**③-d 재조준 (2026-08-24, Phase 7 웨이브 3)**: `post-edit-review-gate.sh`
는 v1 커밋/편집 게이트 전면 교대(순차 디스패처 + 규율/리뷰 분리 훅
체계)로 이 저장소에서 삭제됐다 — 형제 워커(편집 게이트 축)의 작업.
그 훅과 정확히 동일한 루프 구조(소스 확장자를 찾으면 `break`, 그
`break` 직전에 `shadow_capture_set_subject()` 호출)를 가진 생존
훅(`post-edit-src-touch-marker.sh` — `trail/dod/.session-has-src-edit`
producer, "이번 세션에 소스를 편집했는가" 북키핑)으로 시나리오 2/3 과
권한 테스트를 재조준한다. 게이트 본연의 동작 확인(구: `.review-pending`
생성 여부)도 이 훅의 실제 산출물(`.session-has-src-edit` marker, 소스
편집에서만 생성)로 대응 갱신했다 — capture subject 정합성이라는 이
스위트의 본래 계약(회귀 테스트 대상)은 marker 파일명이 무엇이든 동일한
루프-구조 버그 클래스를 검증한다.

이 테스트는 mock 이 아니라 **실제 v1 훅 프로세스를 구동**해 결과
corpus record 의 `command.redacted` (capture 가 command_text 를 담는
필드 — 이 훅들은 셸 커맨드가 아니라 편집된 파일 경로를 그 자리에
싣는다) 가 비어있지 않은지 확인한다. 3 시나리오:
  1. 설계 문서 편집 (post-edit-spec-review-gate.sh, break 없는 훅)
  2. 비소스 편집 (post-edit-src-touch-marker.sh, break 를 못 타는 경로)
  3. 소스 편집 (post-edit-src-touch-marker.sh, break 경로 — 회귀 없음
     고정)

fire-and-forget 계약(백그라운드 서브셸 + disown) 때문에 훅 프로세스가
끝난 뒤에도 python 기록이 비동기로 완료된다 — 이는 훅의 exit
code/latency 와 무관한 순수 테스트 관측 문제이므로, corpus 파일에 새
줄이 나타날 때까지 짧게 폴링한다.
"""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

_TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # plugins/rein-core/tests
_PLUGIN_ROOT = os.path.dirname(_TESTS_DIR)                                # plugins/rein-core
_HOOKS_DIR = os.path.join(_PLUGIN_ROOT, "hooks")

CORPUS_RELATIVE = os.path.join(".rein", "state", "shadow-corpus.jsonl")

POLL_TIMEOUT_S = 5.0
POLL_INTERVAL_S = 0.05

# subprocess 환경에서 반드시 벗겨내야 하는 키 — 캐시/plugin-root/git 경로가
# 남아 있으면 fixture 프로젝트가 아닌 다른 대상으로 훅이 동작할 수 있다
# (spike2 harness `run_hook` 와 동일한 격리 원칙).
_ENV_STRIP_KEYS = (
    "CLAUDE_PLUGIN_ROOT",
    "CLAUDE_PROJECT_DIR",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "REIN_HOOK_INPUT_CACHE",
    "REIN_HOOK_INPUT_FILE",
    "REIN_HOOK_FILE_PATHS",
    "REIN_HOOK_FILE_PATH",
)


def _make_project(tmp_dir):
    for sub in ("trail/dod", "trail/inbox", "trail/incidents", "docs/specs"):
        os.makedirs(os.path.join(tmp_dir, sub), exist_ok=True)


def _edit_envelope(file_path):
    return json.dumps(
        {
            "hook_event_name": "PostToolUse",
            "tool_name": "Edit",
            "tool_input": {"file_path": file_path},
            "tool_response": {"filePath": file_path},
        }
    )


def _run_hook(hook_name, project_dir, envelope):
    hook_path = os.path.join(_HOOKS_DIR, hook_name)
    env = dict(os.environ)
    for key in _ENV_STRIP_KEYS:
        env.pop(key, None)
    env["REIN_PROJECT_DIR_OVERRIDE"] = project_dir
    env["REIN_TEST_MODE"] = "1"
    return subprocess.run(
        ["bash", hook_path],
        input=envelope,
        capture_output=True,
        text=True,
        cwd=project_dir,
        env=env,
        timeout=30,
    )


def _corpus_path(project_dir):
    return os.path.join(project_dir, CORPUS_RELATIVE)


def _read_lines(corpus_path):
    if not os.path.exists(corpus_path):
        return []
    with open(corpus_path, encoding="utf-8") as fh:
        return [ln for ln in fh.read().splitlines() if ln.strip()]


def _wait_for_new_line(corpus_path, before_count, timeout=POLL_TIMEOUT_S):
    """`corpus_path` 에 `before_count` 보다 많은 줄이 생길 때까지 폴링한다.

    fire-and-forget 백그라운드 기록은 훅 프로세스 종료 이후 비동기로
    완료되므로 필요하다 (훅 자체는 결과를 기다리지 않는다 — 계약).
    """
    deadline = time.monotonic() + timeout
    lines = _read_lines(corpus_path)
    while time.monotonic() < deadline and len(lines) <= before_count:
        time.sleep(POLL_INTERVAL_S)
        lines = _read_lines(corpus_path)
    return lines


class HookCaptureSubjectTest(unittest.TestCase):
    """실제 v1 훅 2종을 구동해 shadow capture record 의 subject
    (`command.redacted`) 가 비어있지 않은지 검증한다 (행위 기반, mock 없음)."""

    def setUp(self):
        self._tmp = os.path.realpath(tempfile.mkdtemp(prefix="rein-shadow-subject-"))
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)
        _make_project(self._tmp)

    # ------------------------------------------------------------------
    # 시나리오 1: 설계 문서 편집 — post-edit-spec-review-gate.sh (break 없음)
    # ------------------------------------------------------------------
    def test_design_doc_edit_records_nonempty_subject(self):
        spec_path = os.path.join(self._tmp, "docs", "specs", "target-spec.md")
        with open(spec_path, "w", encoding="utf-8") as fh:
            fh.write("# fixture design spec\n")

        before = len(_read_lines(_corpus_path(self._tmp)))
        proc = _run_hook(
            "post-edit-spec-review-gate.sh", self._tmp, _edit_envelope(spec_path)
        )
        # 게이트 불변 계약: exit code 는 capture 삽입 전과 동일해야 한다.
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        # 게이트 본연의 동작도 같이 고정 — canonical spec 편집은 pending
        # marker 를 만든다 (capture 삽입이 이 동작을 방해하지 않음을 확인).
        self.assertTrue(
            os.path.isdir(os.path.join(self._tmp, "trail", "dod", ".spec-reviews")),
            "spec pending marker 디렉토리가 생성되지 않음 — 게이트 동작 회귀",
        )

        lines = _wait_for_new_line(_corpus_path(self._tmp), before)
        self.assertGreater(
            len(lines), before, "shadow capture record 가 기록되지 않음 (fire-and-forget 완료 대기 초과)"
        )
        record = json.loads(lines[-1])
        self.assertEqual(record["event"], "post-edit-spec-review-gate")
        self.assertEqual(
            record["command"]["redacted"],
            os.path.relpath(spec_path, self._tmp),
            "subject(command.redacted) 가 빈 값이거나 편집된 경로와 다름 — 회귀. "
            "2026-08-10 부터 프로젝트 루트 기준 상대경로로 축약된다 "
            "(사용자명 유출 방지 + corpus 반입 통과, test_path_normalize.py 참조)",
        )

    # ------------------------------------------------------------------
    # 시나리오 2: 비소스 편집 — post-edit-src-touch-marker.sh (break 를
    # 못 타는 경로. ③-d 재조준 — 구 post-edit-review-gate.sh 삭제, 모듈
    # docstring "③-d 재조준" 절 참조)
    # ------------------------------------------------------------------
    def test_non_source_edit_records_nonempty_subject(self):
        notes_path = os.path.join(self._tmp, "notes.txt")
        with open(notes_path, "w", encoding="utf-8") as fh:
            fh.write("fixture note\n")

        before = len(_read_lines(_corpus_path(self._tmp)))
        proc = _run_hook(
            "post-edit-src-touch-marker.sh", self._tmp, _edit_envelope(notes_path)
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        # 게이트 본연의 동작 고정 — 비소스 편집은 .session-has-src-edit
        # 를 만들지 않는다(FOUND_SOURCE=false 이므로 touch 자체가
        # 스킵됨).
        self.assertFalse(
            os.path.exists(
                os.path.join(self._tmp, "trail", "dod", ".session-has-src-edit")
            ),
            "비소스 편집인데 .session-has-src-edit 이 생성됨 — 훅 동작 회귀",
        )

        lines = _wait_for_new_line(_corpus_path(self._tmp), before)
        self.assertGreater(
            len(lines), before, "shadow capture record 가 기록되지 않음 (fire-and-forget 완료 대기 초과)"
        )
        record = json.loads(lines[-1])
        self.assertEqual(record["event"], "post-edit-src-touch-marker")
        self.assertEqual(
            record["command"]["redacted"],
            os.path.relpath(notes_path, self._tmp),
            "subject(command.redacted) 가 빈 값이거나 편집된 경로와 다름 — 회귀 "
            "(2026-08-10 code review MEDIUM). 경로는 프로젝트 루트 기준 상대경로로 축약된다.",
        )

    # ------------------------------------------------------------------
    # 시나리오 3: 소스 편집 — post-edit-src-touch-marker.sh (break 경로,
    # 회귀 없음 고정. ③-d 재조준)
    # ------------------------------------------------------------------
    def test_source_edit_records_nonempty_subject(self):
        src_path = os.path.join(self._tmp, "app.py")
        with open(src_path, "w", encoding="utf-8") as fh:
            fh.write("print('fixture')\n")

        before = len(_read_lines(_corpus_path(self._tmp)))
        proc = _run_hook(
            "post-edit-src-touch-marker.sh", self._tmp, _edit_envelope(src_path)
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        # 게이트 본연의 동작 고정 — 소스 편집은 .session-has-src-edit 를
        # 만든다(FOUND_SOURCE=true, break 경로).
        self.assertTrue(
            os.path.exists(
                os.path.join(self._tmp, "trail", "dod", ".session-has-src-edit")
            ),
            ".session-has-src-edit 가 생성되지 않음 — 훅 동작 회귀",
        )

        lines = _wait_for_new_line(_corpus_path(self._tmp), before)
        self.assertGreater(
            len(lines), before, "shadow capture record 가 기록되지 않음 (fire-and-forget 완료 대기 초과)"
        )
        record = json.loads(lines[-1])
        self.assertEqual(record["event"], "post-edit-src-touch-marker")
        self.assertEqual(
            record["command"]["redacted"],
            os.path.relpath(src_path, self._tmp),
            "subject(command.redacted) 가 빈 값이거나 편집된 경로와 다름. "
            "경로는 프로젝트 루트 기준 상대경로로 축약된다.",
        )

    # ------------------------------------------------------------------
    # 산출물 권한 — capture 신규 파일은 소유자 전용(0600) 이어야 한다
    # (`rein.platform.storage.local` SSOT 계약, Task 2.5). ③-d 재조준.
    # ------------------------------------------------------------------
    @unittest.skipUnless(os.name == "posix", "POSIX 파일 권한 계약")
    def test_corpus_file_created_with_owner_only_permissions(self):
        src_path = os.path.join(self._tmp, "app.py")
        with open(src_path, "w", encoding="utf-8") as fh:
            fh.write("print('fixture')\n")

        before = len(_read_lines(_corpus_path(self._tmp)))
        proc = _run_hook(
            "post-edit-src-touch-marker.sh", self._tmp, _edit_envelope(src_path)
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        lines = _wait_for_new_line(_corpus_path(self._tmp), before)
        self.assertGreater(len(lines), before, "shadow capture record 가 기록되지 않음")

        corpus_path = _corpus_path(self._tmp)
        mode = stat.S_IMODE(os.stat(corpus_path).st_mode)
        self.assertEqual(mode, 0o600, "corpus 파일 권한이 0600 이 아님")


if __name__ == "__main__":
    unittest.main()
