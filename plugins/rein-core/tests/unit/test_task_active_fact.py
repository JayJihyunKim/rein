"""platform.task.facts.task_active_identifier — v1 DOD_FOUND 동등 재현
(v2 Phase 6 worker D — spec §3.6 §10, active_task capability 계약).

v1 `hooks/pre-edit-dod-gate.sh` (라인 448-479) 의 pending 판정: 신 포맷
`trail/dod/dod-YYYY-MM-DD-<slug>.md` 파일이 존재하고 같은 slug 의
`trail/inbox/YYYY-MM-DD-<slug>.md` 완료 기록이 없으면 "활성 작업 있음"
이다. **Phase 7 웨이브 3 ③-d 갱신**: `rein.engine.authority` 는 legacy
marker dual-read 계층 전체가 제거되며 이 DOD_FOUND 로직의 legacy
판정용 대응 함수(`_legacy_active_task_status`)를 더 이상 갖지 않는다
— 이 모듈은 애초에 그 함수를 import 하지 않았으므로(engine 모듈은
import 하지 않는다 — capability fact 소스는 platform 소관, spec §3.1)
이 제거는 이 모듈이 테스트하는 판정 로직에 영향을 주지 않는다(무변경)
— 아래 테스트들이 검증하는 재현 로직은 여전히 이 모듈이 유지하는
유일한 DOD_FOUND 구현이다.

`rein.capabilities.task.capability.FACT_TASK_ACTIVE` 계약: 값은 `str`
(비어있지 않으면 활성 식별자) 또는 `None`(활성 작업 없음)이어야 한다.
"""
import os
import sys
import tempfile
import unittest
import unittest.mock

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.platform.task import facts  # noqa: E402


def _write(path, content="stub\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


class NoTrailDirectoryTest(unittest.TestCase):
    """trail/ 또는 trail/dod/ 자체가 없으면 활성 작업 없음(부재, 예외 아님)."""

    def test_missing_trail_dir_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(facts.task_active_identifier(root))

    def test_missing_dod_dir_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "trail", "inbox"))
            self.assertIsNone(facts.task_active_identifier(root))

    def test_empty_dod_dir_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "trail", "dod"))
            self.assertIsNone(facts.task_active_identifier(root))


class PendingDodTest(unittest.TestCase):
    """신 포맷 dod 파일 + 미매칭 inbox = 활성. 매칭 inbox = 완료(비활성)."""

    def test_single_pending_dod_is_active(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            identifier = facts.task_active_identifier(root)
            self.assertEqual(identifier, "dod-2026-08-11-foo")

    def test_completed_dod_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-foo.md")
            )
            self.assertIsNone(facts.task_active_identifier(root))

    def test_mixed_pending_and_completed_returns_the_pending_one(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-bar.md")
            )
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-bar.md")
            )
            identifier = facts.task_active_identifier(root)
            self.assertEqual(identifier, "dod-2026-08-11-foo")

    def test_all_completed_is_absent(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-bar.md")
            )
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-bar.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-foo.md")
            )
            self.assertIsNone(facts.task_active_identifier(root))

    def test_legacy_filename_format_is_ignored(self):
        # v1 은 신 포맷(dod-YYYY-MM-DD-slug.md) 만 pending 판정에 쓴다 —
        # 레거시 포맷 파일은 별도 스윕 대상이고 이 fact 판정에는 무관.
        with tempfile.TemporaryDirectory() as root:
            _write(os.path.join(root, "trail", "dod", "old-notes.md"))
            self.assertIsNone(facts.task_active_identifier(root))

    def test_inbox_slug_match_is_exact_not_prefix(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            # inbox 의 slug 는 "foo-extra" 이지 "foo" 가 아니다 — prefix
            # 매칭이면 오탐으로 완료 처리될 위험을 고정한다.
            _write(
                os.path.join(
                    root, "trail", "inbox", "2026-08-11-foo-extra.md"
                )
            )
            identifier = facts.task_active_identifier(root)
            self.assertEqual(identifier, "dod-2026-08-11-foo")

    def test_missing_inbox_dir_treats_all_dod_files_as_pending(self):
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            identifier = facts.task_active_identifier(root)
            self.assertIsNotNone(identifier)

    def test_multiple_concurrently_pending_dods_selects_first_by_sorted_filename_order(self):
        # test_mixed_pending_and_completed_returns_the_pending_one 은 완료
        # 1개 + 미완료 1개 조합이라 "미완료가 하나뿐일 때" 만 고정한다.
        # 이 테스트는 미완료(inbox 미매칭) DoD 파일이 **2개 이상 동시
        # 존재**할 때 `sorted(os.listdir(dod_dir))` 순서상 첫 항목이
        # 반환되는지를 직접 고정한다(facts.py 모듈 docstring "여러 dod
        # 파일이 있으면 정렬 순서로 첫 pending 항목을 반환" 계약).
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-zeta.md")
            )
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-alpha.md")
            )
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-mid.md")
            )
            identifier = facts.task_active_identifier(root)
            self.assertEqual(identifier, "dod-2026-08-11-alpha")


class ContractTypeTest(unittest.TestCase):
    """capability 계약(str 비어있지 않음 또는 None)을 만족하는 반환 타입."""

    def test_result_type_is_str_or_none(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(facts.task_active_identifier(root))
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            result = facts.task_active_identifier(root)
            self.assertIsInstance(result, str)
            self.assertTrue(result)


class TaskExistsFactTest(unittest.TestCase):
    """`task.exists` fact — v1 커밋 게이트 술어(`dod_exists`)의 미러.

    High-1 리뷰 지적(2026-08-19, 리뷰어 실재현)으로 구현 방향이 바뀌었다
    — 이전 구현은 `task_active_identifier()`(신 포맷 정규식 강제 + inbox
    완료 대조)를 그대로 재사용해 `task_exists()` 를 파생했지만, 그
    결과 위임·등록 경로에서 "완료-but-파일-잔존" 창과 레거시 파일명
    케이스에서 v1(`hooks/lib/code-review-gate.sh` 의 `dod_exists`,
    파일명 glob `dod-*.md` 매치만 보고 완료 여부·날짜 형식은 무관)이
    요구하던 리뷰가 오늘부터 사라졌다(동작 불변 계약 위반). 이 클래스는
    이제 `task_exists()` 가 `trail/dod/` 의 `dod-*.md` 파일명 글롭만
    보는지(inbox 완료 대조 없음, 날짜 형식 강제 없음, `task_facts.
    task_exists()` docstring 참조)를 고정한다.

    **[방향 교체]** — 옛 기대(완료-but-파일잔존 → None, 레거시 파일명
    → None)는 지워지지 않고 각 테스트 안에서 **반대 방향**("true")으로
    교체됐다. 근거는 동작 불변 계약(v1 술어 보존) — 아래 각 테스트의
    docstring/주석에 옛 기대와 그 근거를 함께 남긴다.
    """

    def test_active_task_yields_exact_true_literal(self):
        # 표준 케이스 — 신 포맷 pending 파일 1건. v1 glob 과 v2 스캐너가
        # 둘 다 "true" 로 일치하는 대조군(다른 테스트들의 방향 교체가
        # 예외적 구간에서만 발생함을 보여준다). 정확히 문자열 "true" —
        # 다른 truthy 값(예: bool True, 식별자 문자열 자체)이 아니다.
        # policy YAML `when:` 비교는 D3 서브셋의 문자열 exact-match 이므로,
        # 리터럴이 조금이라도 다르면 조건화가 조용히 항상 불일치하는
        # 회귀가 된다.
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            value = facts.task_exists(root)
            self.assertEqual(value, "true")
            self.assertIsInstance(value, str)
            self.assertNotIsInstance(value, bool)

    def test_no_dod_files_yields_none(self):
        # trail/dod/ 디렉토리 자체가 없음 — v1 의 `[ -d "$dod_dir" ]`
        # 가드와 동일하게 None.
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(facts.task_exists(root))

    def test_empty_dod_dir_yields_none(self):
        # trail/dod/ 는 있지만 dod-*.md 글롭에 매치되는 파일이 전무 —
        # v1 의 for 루프가 한 번도 안 돌아 dod_exists=false 로 남는
        # 것과 동일. "디렉토리 존재"가 아니라 "매치 파일 존재"가 판정
        # 기준이라는 것을 위 no-dir 케이스와 분리해 고정한다.
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "trail", "dod"))
            self.assertIsNone(facts.task_exists(root))

    def test_completed_task_file_still_present_yields_true(self):
        # [방향 교체] 이전 기대: None("완료면 비관련" — task_active_
        # identifier() 재사용 시절의 판정). 새 기대: "true".
        # 근거(High-1 리뷰, 동작 불변 계약): v1 `dod_exists`
        # (`code-review-gate.sh` 라인 302-315, `for f in "$dod_dir"/
        # dod-*.md`)는 `trail/dod/` 파일 존재만 보고 `trail/inbox/`
        # 완료 기록을 전혀 대조하지 않는다 — inbox 조회 자체가 없다.
        # `task_active_identifier()` 를 재사용해 완료 판정을 얹으면 이
        # v1 술어와 갈라져, "완료 처리됐지만 정의서 파일을 아직 안 지운"
        # 흔한 운영 창에서 v1 이 계속 요구하던 리뷰가 v2 위임 경로에서
        # 조용히 사라진다(리뷰어 실재현) — 그래서 이 fact 는 inbox 를
        # 아예 보지 않는다.
        with tempfile.TemporaryDirectory() as root:
            _write(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-foo.md")
            )
            _write(
                os.path.join(root, "trail", "inbox", "2026-08-11-foo.md")
            )
            self.assertEqual(facts.task_exists(root), "true")

    def test_legacy_filename_without_date_yields_true(self):
        # [방향 교체] 이전 기대: None("레거시 포맷은 무시" —
        # task_active_identifier() 의 신 포맷 정규식 강제를 상속하던
        # 시절의 판정). 새 기대: "true".
        # 근거(High-1 리뷰, 동작 불변 계약): v1 `dod_exists` 의 셸 glob
        # `dod-*.md` 는 `dod-` 로 시작하고 `.md` 로 끝나기만 하면
        # 매칭한다 — 날짜 형식(`YYYY-MM-DD`)을 전혀 요구하지 않는다.
        # `task_active_identifier()` 의 신 포맷 정규식(날짜 세그먼트
        # 강제)을 재사용하면 레거시 파일명만 있는 상태에서 v1 이
        # 요구하던 리뷰가 사라진다.
        with tempfile.TemporaryDirectory() as root:
            _write(os.path.join(root, "trail", "dod", "dod-notes.md"))
            self.assertEqual(facts.task_exists(root), "true")

    def test_directory_entry_named_like_glob_is_not_a_match(self):
        # v1 의 `[ -f "$f" ]` 가드 미러 — `dod-*.md` 이름에 매치되는
        # 항목이라도 일반 파일이 아니라 디렉토리면 매치로 치지 않는다.
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(
                os.path.join(root, "trail", "dod", "dod-2026-08-11-dir.md")
            )
            self.assertIsNone(facts.task_exists(root))

    def test_scanner_exception_propagates_not_swallowed_to_none(self):
        # 실패 방향(DoD 필수 지시, 예외 전파 유지) — trail/dod/ 를 여는
        # 디렉토리 레벨 스캔(os.scandir)이 예외를 던지면 task_exists()
        # 는 그것을 None 으로 삼키지 않고 그대로 전파해야 한다.
        # task_exists() 는 High-1 리뷰 이후 `os.scandir(dod_dir)` 로
        # 디렉토리를 여는 구현으로 바뀌었으므로(흡수형 os.path.isdir 을
        # 더 이상 쓰지 않음, facts.py task_exists() docstring "실패
        # 방향" 절 참조), 실제 I/O 지점인 `os.scandir` 자체를 패치해
        # 이 경로를 실측 재현한다(이전의 `os.listdir` patch 는 새 구현
        # 에서 더 이상 호출되지 않아 이 경계를 통과하지 못한다).
        # 삼키면(예외 → None) 스캐너 버그가 policy `when:` 불일치를
        # 유발해 리뷰 게이트를 조용히 꺼버리는 fail-open 이 된다 — 이
        # 저장소의 게이트 계열 "판단 불능 = 거부 방향" 원칙과 정면으로
        # 어긋난다.
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "trail", "dod"))

            def _boom(_path):
                raise OSError("simulated directory-level scanner failure")

            with unittest.mock.patch("os.scandir", side_effect=_boom):
                with self.assertRaises(OSError):
                    facts.task_exists(root)

    def test_stat_permission_error_on_entry_propagates_not_swallowed(self):
        # High-1 리뷰어의 실제 재현 방식 — 디렉토리 자체는 정상적으로
        # 열리지만(os.scandir 성공), 개별 항목의 파일 여부 판정
        # (entry.is_file(), 내부적으로 os.stat() 에 해당)이 권한 오류를
        # 던지는 경우. 실측(구현 전 실험): 이 저장소가 도는 macOS
        # APFS 환경에서는 `entry.is_file()` 이 readdir 의 d_type 캐시를
        # 쓰기 때문에 `os.stat` 자체를 patch 해도 그 호출이 걸리지
        # 않는다 — 그래서 이 테스트는 구현이 실제로 지나는 정확한
        # 경계인 `os.DirEntry.is_file` 자체를 patch 해 stat 실패를
        # 재현한다(형식적 mock 이 아니라 실측 확인된 호출 지점).
        # 이전의 흡수형 구현(`os.path.isfile()` 사용)은 이 오류를
        # `False` 로 삼켜 루프가 계속 돌다 결국 None(정의서 없음)을
        # 반환했다 — 권한 오류가 "리뷰 불필요"로 위장되는 fail-open.
        # 수리 후 구현은 이 예외를 그대로 전파해야 한다.
        with tempfile.TemporaryDirectory() as root:
            dod_dir = os.path.join(root, "trail", "dod")
            os.makedirs(dod_dir)
            with open(
                os.path.join(dod_dir, "dod-2026-08-11-foo.md"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("stub\n")

            def _boom_is_file(self, *, follow_symlinks=True):
                raise PermissionError("simulated stat-level failure")

            with unittest.mock.patch.object(
                os.DirEntry, "is_file", _boom_is_file
            ):
                with self.assertRaises(PermissionError):
                    facts.task_exists(root)


if __name__ == "__main__":
    unittest.main()
