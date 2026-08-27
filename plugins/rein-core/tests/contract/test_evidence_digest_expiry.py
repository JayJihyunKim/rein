"""plan Task 2.1 (b) — Evidence subject digest 만료 계약 (spec §3.3, §3.4).

review PASS Evidence 는 생성 당시 ChangeSet digest 를 subject 로 결속한다.
코드가 수정되어 현재 digest 가 달라지면 `subject_matches` 가 거짓이 되어
해당 Requirement 는 재평가에서 미충족이다. mtime 만 바뀐 경우(touch)는
digest 가 불변이므로 만료되지 않는다 — 만료 축은 내용이지 시각이 아니다.
digest 축은 policy version 축과 서로 독립인 무효화 축이다 (spec §3.4).
"""
import os
import sys
import tempfile
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.kernel.changeset import content_digest  # noqa: E402
from rein.kernel.evidence import (  # noqa: E402
    Evidence,
    PRODUCER_AGENT_ATTESTED,
    policy_version_valid,
    subject_matches,
)


def _fs_reader(base):
    def read_content(path):
        try:
            with open(os.path.join(base, path), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    return read_content


class EvidenceDigestExpiryTest(unittest.TestCase):
    """review PASS → 코드 수정 → digest 변경 → 재평가 미충족."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = tmp.name
        self.path = os.path.join(self.base, "mod.py")
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")
        self.reader = _fs_reader(self.base)
        self.initial_digest = content_digest(("mod.py",), self.reader)
        # Reviewer PASS 를 Runtime 이 당시 digest 와 결합해 발급한
        # code_review Evidence (spec §3.6 — PASS 반환만으로 자동 인정 안 됨)
        self.evidence = Evidence(
            type="code_review",
            subject=self.initial_digest,
            result="PASS",
            created_at="2026-08-08T00:00:00+00:00",
            producer=PRODUCER_AGENT_ATTESTED,
            policy_version="1",
        )

    def _current_digest(self):
        return content_digest(("mod.py",), self.reader)

    def test_evidence_satisfies_while_content_unchanged(self):
        self.assertTrue(subject_matches(self.evidence, self._current_digest()))

    def test_touch_does_not_expire_evidence(self):
        # mtime 은 validity 근거가 아니다 (spec §3.3) — touch 만으로
        # 리뷰를 만료시키면 v1 게이트 freshness 오탐 클래스가 재발한다
        stat = os.stat(self.path)
        os.utime(self.path, (stat.st_atime + 3600, stat.st_mtime + 3600))
        self.assertTrue(subject_matches(self.evidence, self._current_digest()))

    def test_code_edit_after_pass_leaves_requirement_unmet(self):
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")
        current = self._current_digest()
        self.assertNotEqual(current, self.initial_digest)
        # subject 불일치 = 이 Evidence 로는 code_review Requirement 를
        # 충족시킬 수 없다 — 재평가는 미충족으로 판정한다
        self.assertFalse(subject_matches(self.evidence, current))

    def test_revert_to_reviewed_content_restores_match(self):
        # 내용 기준의 대우 검증 — 원래 내용으로 되돌리면 다시 일치한다
        # (시각 기준이었다면 되돌려도 만료가 유지된다)
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")
        self.assertFalse(
            subject_matches(self.evidence, self._current_digest())
        )
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")
        self.assertTrue(subject_matches(self.evidence, self._current_digest()))

    def test_digest_axis_is_independent_of_policy_version_axis(self):
        # spec §3.4 — subject digest 는 policy version 과 독립.
        # 코드 수정: version 축은 여전히 유효, digest 축만 만료
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 2\n")
        self.assertTrue(policy_version_valid(self.evidence, "1"))
        self.assertFalse(
            subject_matches(self.evidence, self._current_digest())
        )
        # version bump (내용 원복): digest 축은 유효, version 축만 무효
        with open(self.path, "wb") as handle:
            handle.write(b"VALUE = 1\n")
        self.assertTrue(subject_matches(self.evidence, self._current_digest()))
        self.assertFalse(policy_version_valid(self.evidence, "2"))


if __name__ == "__main__":
    unittest.main()
