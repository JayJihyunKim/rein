"""plan Task 2.3 — 보수적 명령 분류기 corpus (spec §3.2, §6.3).

covers: command-classifier-labels-compound-and-expansion-commands-unknown-without-guessing

계약:
- 단순 명령은 정확 분류 (`git commit ...` → git.commit, `ls -la` → ls).
- 복합/불확실은 전부 UNKNOWN — `&&`·`||`·`;`·파이프·`$( )`·백틱·eval·
  변수 확장·중첩 shell(`bash -c`)·리다이렉션·wrapper(sudo/env/xargs)·
  할당 접두·인용 불균형. 완전 파싱 시도 금지 (Fact Resolver 는 Shell
  Sandbox 가 아니다) — 판단 불가면 unknown.
- v1 오판 사례 이식 (spec §6.3): 데이터(인용 문자열·heredoc 본문)로만
  등장하는 `git commit` 텍스트를 실행 명령으로 오인하지 않는다 +
  샌드박스 커밋(compound cd / `git -C`)을 git.commit 으로 단정하지
  않는다.
- unknown 분류는 기존 evaluator 로 stricter policy 경로에 매칭된다
  (evaluator/runtime 은 읽기 전용 — 본 테스트는 배선만 검증).

완료 판정: unknown 과소 판정(복합 명령을 단순으로 오분류) 0건 —
COMPOUND/UNCERTAIN corpus 전 항목이 UNKNOWN 이어야 한다.
"""
import os
import sys
import unittest

_PLUGIN_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, _PLUGIN_ROOT)

from rein.engine import command_classifier, evaluator  # noqa: E402
from rein.engine.command_classifier import (  # noqa: E402
    FACT_KEY,
    UNKNOWN,
    classify,
)
from rein.engine.context import EvaluationContext  # noqa: E402
from rein.kernel import policy as kernel_policy  # noqa: E402
from rein.kernel.decision import (  # noqa: E402
    DECISION_ALLOW,
    DECISION_BLOCK,
)

# ---------------------------------------------------------------------------
# corpus — 단순 명령: 정확 분류 (command, expected label)
# ---------------------------------------------------------------------------
SIMPLE_CORPUS = (
    ("git commit -m 'fix(scope): bug'", "git.commit"),
    ('git commit -m "feat(v2): task"', "git.commit"),
    ("git push origin dev", "git.push"),
    ("git status --short", "git.status"),
    ("git add -A", "git.add"),
    ("git log --oneline -5", "git.log"),
    ("git diff --stat", "git.diff"),
    ("git rev-parse HEAD", "git.rev-parse"),
    ("ls -la", "ls"),
    ("pytest tests/unit -q", "pytest"),
    ("python3 -m unittest discover", "python3"),
    ("grep -rn TODO plugins/rein-core", "grep"),
    ("mkdir -p build/tmp", "mkdir"),
    ("rm -rf build/tmp", "rm"),
    ("git add *.py", "git.add"),
)

# ---------------------------------------------------------------------------
# corpus — 복합/불확실: 전부 UNKNOWN (과소 판정 0건 판정 대상)
# ---------------------------------------------------------------------------
COMPOUND_CORPUS = (
    # 연결 연산자
    "git add -A && git commit -m 'x'",
    "git commit -m 'a' || echo failed",
    "git status; git commit -m 'x'",
    "git log --oneline | head -5",
    "sleep 5 & echo bg",
    # 치환 / 확장
    "echo $(git rev-parse HEAD)",
    "echo `git rev-parse HEAD`",
    'git commit -m "$MSG"',
    "echo $HOME",
    "echo ${PATH}",
    # eval / 중첩 shell / 인터프리터 inline code
    "eval 'git commit -m x'",
    "bash -c 'git commit -m x'",
    "sh script.sh",
    "zsh -c 'ls'",
    "python3 -c 'import subprocess'",
    # 리다이렉션 (heredoc 포함)
    "git log > /tmp/out.txt",
    "wc -l < input.txt",
    "echo hi >> log.txt",
    "cat <<EOF\ngit commit -m fake\nEOF",
    # wrapper / 할당 접두 / git 전역 옵션
    "sudo git commit -m 'x'",
    "env GIT_DIR=/tmp/x git commit -m 'x'",
    "FOO=bar git commit -m 'x'",
    "xargs rm",
    "find . -name '*.pyc' -delete",
    "git -C /tmp/sandbox commit -m 'x'",
    # 구조 판단 불가
    "git commit -m 'unterminated",
    'git commit -m "unterminated',
    "g\\it commit -m 'x'",
    "/tmp/build.sh",
    "./run.sh --fast",
    "",
    "   ",
)

# ---------------------------------------------------------------------------
# v1 오판 사례 이식 (spec §6.3) — 절대 git.commit 으로 분류되면 안 되는 입력
# ---------------------------------------------------------------------------
V1_NEVER_GIT_COMMIT = (
    # 스크립트/인자 데이터로만 등장하는 `git commit` 텍스트 (GSD-3 계열)
    ("grep -rn 'git commit' plugins/rein-core/hooks", "grep"),
    ("echo 'git commit -m fake'", "echo"),
    ("printf '%s' 'line1\ngit commit -m fake'", "printf"),
    # heredoc 본문의 `git commit` 줄 (샌드박스 재현 스크립트 작성 실측)
    (
        "cat > repro.sh <<'EOF'\ngit commit -m \"sandbox repro\"\nEOF",
        UNKNOWN,
    ),
    # 샌드박스 커밋 (compound cd / git -C) — 단순 git.commit 단정 금지
    ("cd /tmp/repro-sandbox && git commit -m 'repro'", UNKNOWN),
    ("git -C /tmp/repro-sandbox commit -m 'repro'", UNKNOWN),
)


# ---------------------------------------------------------------------------
# corpus — 대소문자 변형 (보안 리뷰 fail-open 재현, spec §3.2)
#
# macOS 등 대소문자 비구분 파일시스템에서는 선두 토큰의 대소문자와 무관
# 하게 동일한 바이너리가 resolve 된다. 대소문자만 바꾼 wrapper/shell/
# interpreter 호출은 기존 소문자 형태와 최소 동일한 보수성(unknown)을
# 가져야 하고, git 서브커맨드는 소문자 형태와 동일한 라벨
# (``git.<subcommand>``) 로 수렴해야 하위 policy 매칭이 대소문자 변형
# 으로 우회되지 않는다.
# ---------------------------------------------------------------------------
CASE_VARIANT_UNKNOWN_CORPUS = (
    "Sudo git push",  # 보안 리뷰 재현 케이스 2
    "Bash -c 'rm -rf /'",  # 보안 리뷰 재현 케이스 3
    "Eval echo hi",  # 보안 리뷰 재현 케이스 4
    "BASH -c 'ls -la'",  # 전체 대문자
    "sUdO rm -rf /",  # 대소문자 혼용
    "Python3 -c 'import os'",  # 인터프리터 inline 코드, Title-case
    "ZSH -c 'ls'",
    "Env GIT_DIR=/tmp/x git commit -m 'x'",
    "Find . -name '*.pyc' -delete",
)

CASE_VARIANT_GIT_LABEL_CORPUS = (
    ("Git commit -m x", "git.commit"),  # 보안 리뷰 재현 케이스 5
    ("GIT commit -m x", "git.commit"),  # 전체 대문자 head
    ("gIt push origin dev", "git.push"),  # head 대소문자 혼용
)


def _load_inline_policy(policy_id, text):
    """실로더(parse_policy)를 지나는 형태로 policy fixture 를 만든다."""
    return {
        "policy_id": policy_id,
        "fields": kernel_policy.parse_policy(
            text, source="<test:{}>".format(policy_id)
        ),
    }


# unknown 분류 명령에만 걸리는 강화 policy — user_approval 요구
_UNKNOWN_STRICT_POLICY = _load_inline_policy(
    "strict-on-unknown-command",
    "trigger: tool.pre\n"
    "when:\n"
    "  command.type: unknown\n"
    "require:\n"
    "  - user_approval\n"
    "failure_mode: closed\n",
)


class SimpleCommandCorpusTest(unittest.TestCase):
    """단순 명령은 정확 분류된다 (spec §3.2)."""

    def test_simple_commands_classify_exactly(self):
        for command, expected in SIMPLE_CORPUS:
            with self.subTest(command=command):
                self.assertEqual(classify(command), expected)


class CompoundUnknownCorpusTest(unittest.TestCase):
    """복합/불확실 명령은 전부 unknown — 과소 판정 0건 (완료 판정)."""

    def test_compound_and_uncertain_commands_are_unknown(self):
        for command in COMPOUND_CORPUS:
            with self.subTest(command=command):
                self.assertEqual(classify(command), UNKNOWN)

    def test_non_string_input_is_unknown(self):
        self.assertEqual(classify(None), UNKNOWN)
        self.assertEqual(classify(42), UNKNOWN)

    def test_no_compound_case_underflags_to_simple_label(self):
        # 완료 판정의 직접 표현: COMPOUND corpus 에서 unknown 이 아닌
        # 라벨이 하나라도 나오면 과소 판정 — 위반 목록을 통째로 보여준다.
        underflagged = [
            (command, classify(command))
            for command in COMPOUND_CORPUS
            if classify(command) != UNKNOWN
        ]
        self.assertEqual(underflagged, [])


class V1MisjudgmentPortTest(unittest.TestCase):
    """v1 오판 사례 이식 (spec §6.3) — 데이터 텍스트/샌드박스 커밋."""

    def test_ported_cases_never_classify_as_git_commit(self):
        for command, expected in V1_NEVER_GIT_COMMIT:
            with self.subTest(command=command):
                label = classify(command)
                self.assertNotEqual(label, "git.commit")
                self.assertEqual(label, expected)


class CaseVariantClassificationTest(unittest.TestCase):
    """대소문자 변형 재현 (보안 리뷰) — wrapper/shell/interpreter 는 대소문자
    무관 UNKNOWN, git 서브커맨드는 대소문자 무관 소문자 정규 라벨로
    수렴한다 (spec §3.2 — 기존 소문자 형태와 최소 동일한 보수성).

    근거: macOS 기본 파일시스템은 대소문자를 구분하지 않으므로
    ``Sudo``/``sudo`` 는 실제로 동일한 바이너리를 실행한다. 분류기가
    대소문자를 구분해 wrapper/shell 판정을 놓치면, 판단 불가 시
    unknown 이어야 한다는 계약이 대소문자 변형만으로 우회된다
    (fail-open).
    """

    def test_case_variants_of_wrappers_shells_interpreters_are_unknown(self):
        for command in CASE_VARIANT_UNKNOWN_CORPUS:
            with self.subTest(command=command):
                self.assertEqual(classify(command), UNKNOWN)

    def test_git_head_case_variants_classify_like_lowercase(self):
        for command, expected in CASE_VARIANT_GIT_LABEL_CORPUS:
            with self.subTest(command=command):
                self.assertEqual(classify(command), expected)

    def test_reproduction_cases_from_security_review(self):
        # 보안 리뷰가 보고한 5개 재현 케이스를 그대로 고정한다.
        self.assertEqual(classify("sudo git push"), UNKNOWN)
        self.assertEqual(classify("Sudo git push"), UNKNOWN)
        self.assertEqual(classify("Bash -c 'rm -rf /'"), UNKNOWN)
        self.assertEqual(classify("Eval echo hi"), UNKNOWN)
        self.assertEqual(classify("Git commit -m x"), "git.commit")


class NonAsciiHeadStaysUnknownTest(unittest.TestCase):
    """유니코드 케이스폴딩 인지 회귀 — 동형이의 문자(homoglyph)로 wrapper
    이름을 흉내내도 ASCII 전용 ``_COMMAND_WORD`` 게이트가 막는다.

    대소문자 무관 판정을 ``casefold()`` 로 구현했다고 해서 선두 토큰의
    ASCII 제약이 느슨해지면 안 된다 — 키릴 문자 ``ѕ`` (U+0455) 는
    라틴 ``s`` 와 시각적으로 구분이 안 되지만 별개의 코드포인트이므로
    ``sudo`` 로 매치되지 않고, ``_COMMAND_WORD`` 정규식(ASCII 전용)에도
    걸려 UNKNOWN 이어야 한다.
    """

    def test_cyrillic_lookalike_sudo_head_is_unknown(self):
        lookalike = "ѕudo rm -rf /"
        self.assertEqual(classify(lookalike), UNKNOWN)

    def test_cyrillic_lookalike_git_head_is_unknown(self):
        lookalike = "єit commit -m x"  # 'ѓ' 아님, 'є' 계열 동형이의
        self.assertEqual(classify(lookalike), UNKNOWN)


class ModuleContractTest(unittest.TestCase):
    """분류기 공개 계약 — fact 어휘 고정 (kernel/fact.py 의 예시와 일치)."""

    def test_unknown_constant_value(self):
        self.assertEqual(UNKNOWN, "unknown")

    def test_fact_key_is_command_type(self):
        self.assertEqual(FACT_KEY, "command.type")

    def test_module_reexports_match(self):
        self.assertIs(command_classifier.classify, classify)
        self.assertIs(command_classifier.UNKNOWN, UNKNOWN)


class UnknownRoutesToStricterPolicyTest(unittest.TestCase):
    """unknown fact → 강화 policy 매칭 (기존 evaluator 읽기 전용 배선)."""

    def _decide(self, command):
        facts = {"tool": "Bash", FACT_KEY: classify(command)}
        return evaluator.evaluate(
            "tool.pre",
            EvaluationContext(facts=facts),
            [_UNKNOWN_STRICT_POLICY],
        )

    def test_unknown_command_hits_strict_policy_and_blocks(self):
        # 샌드박스 compound 커밋: unknown → 강화 policy 매칭 →
        # user_approval evidence 부재 → 정상 평가 BLOCK
        decision = self._decide("cd /tmp/sandbox && git commit -m 'repro'")
        self.assertEqual(decision.decision, DECISION_BLOCK)
        self.assertEqual(decision.policy, "strict-on-unknown-command")
        self.assertEqual(decision.missing_requirements, ("user_approval",))

    def test_simple_command_bypasses_strict_policy(self):
        # 단순 명령은 unknown 강화 policy 의 when 에 매칭되지 않는다
        decision = self._decide("git log --oneline -5")
        self.assertEqual(decision.decision, DECISION_ALLOW)
        self.assertIsNone(decision.policy)


if __name__ == "__main__":
    unittest.main()
