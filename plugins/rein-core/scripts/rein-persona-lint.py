#!/usr/bin/env python3
"""rein-persona-lint.py — 커스텀 페르소나 프리셋 생성 lint (L1~L5, spec §4).

CLI:
    python3 rein-persona-lint.py --name <name> --body-file <path>

Contract:
    * all rules pass  -> stdout "PASS", exit 0
    * any violation   -> stdout lists EVERY violated rule ID (L1~L5) with a
      human-readable reason (matched line echoed for L4), exit 1
    * never emits a traceback (internal errors -> exit 1 + reason)
    * --body-file is strictly READ-ONLY here — saving the preset file is the
      persona skill's responsibility, and nothing is written before a pass.

Rules (docs/plans/2026-07-22-persona-user-selection.md Task 4.1, spec §4):
    L1  name format          ^[a-z0-9-]{1,32}$
    L2  builtin collision    name in BUILTIN_PRESETS (filesystem checks — e.g.
                             overwriting an existing custom — are skill-owned;
                             this lint never touches the filesystem beyond
                             reading --body-file)
    L3  size cap             len(body) <= 4,000 chars (after UTF-8 decode)
    L4  forbidden patterns   discipline-erosion phrases + internal ops paths
    L5  frontmatter          leading --- block must contain `summary: <text>`

NOTE: BUILTIN_PRESETS must stay in sync with the loader's
KNOWN_PERSONA_PRESETS (plugins/rein-core/scripts/rein-policy-loader.py) —
parity is enforced by tests/scripts/test-persona-lint.sh.

stdlib only. Plugin single copy — no root scripts/ mirror (hot-path 밖).
"""

import argparse
import re
import sys

# Sync contract: loader KNOWN_PERSONA_PRESETS == this set (see module docstring).
BUILTIN_PRESETS = {"boss-ace", "jennie"}

NAME_RE = re.compile(r"^[a-z0-9-]{1,32}$")
MAX_BODY_CHARS = 4000

# L4 forbidden pattern groups (plan Task 4.1 step 2, verbatim; IGNORECASE).
# Tuned against false-positive fixtures pinned in tests/scripts/
# test-persona-lint.sh — e.g. "차단할 때는 단칼로 말한다" must NOT match.
FORBIDDEN_REGEXES = (
    # ① english prompt-injection style rule/instruction erasure
    re.compile(r"ignore (all |previous |above )?(rules|instructions)", re.IGNORECASE),
    # ② discipline erosion: gate/rule + bypass/weaken verb within 20 chars
    re.compile(
        r"(규칙|지시|게이트|차단|경고|리뷰)[^\n]{0,20}(무시|우회|약화|건너뛰|끄|비활성)",
        re.IGNORECASE,
    ),
    # ③ claiming priority over the invariant response rules
    re.compile(
        r"(response-tone|응답 규칙|불변|invariant)[^\n]{0,20}(보다 우선|이긴다|무효)",
        re.IGNORECASE,
    ),
)
# ④ internal operational paths / identifiers (literal substring match)
FORBIDDEN_LITERALS = ("trail/", ".rein/", "CLAUDE_PLUGIN_ROOT", "hooks/")


def _has_frontmatter_summary(body):
    """True iff a leading `---` frontmatter block is CLOSED by a second `---`
    and contains `summary: <text>` inside it.

    Closure is mandatory (integrated-review fix): an unclosed fence used to be
    accepted here while the hook's awk strip swallowed the entire body as
    frontmatter — lint said PASS, runtime silently injected nothing.
    """
    lines = body.splitlines()
    if not lines or lines[0].strip() != "---":
        return False
    found_summary = False
    for line in lines[1:]:
        if line.strip() == "---":
            return found_summary  # closed — valid only if summary seen inside
        if re.match(r"^summary:\s*\S", line):
            found_summary = True
    return False  # never closed — invalid frontmatter regardless of summary


def _leading_fence_awk_mismatch(text):
    """True iff the lenient parser sees a leading frontmatter fence but the
    hook's awk does NOT — the general (P)∧¬(A) invariant (spec §4).
    (A) MUST be a \\n-literal split on newline-PRESERVING text; str.splitlines()
    would hide CRLF / bare-CR / unicode-separator fences.
    """
    if not text:
        return False
    lines = text.splitlines()
    parser_sees_fence = bool(lines) and lines[0].strip() == "---"
    awk_sees_exact = text.split("\n", 1)[0] == "---"
    return parser_sees_fence and not awk_sees_exact


def check_name(name, violations):
    if not NAME_RE.match(name):
        violations.append(
            "L1: 이름 형식 위반 — 영문 소문자/숫자/하이픈 1~32자만 허용 "
            "(^[a-z0-9-]{1,32}$): '%s'" % name
        )
    if name in BUILTIN_PRESETS:
        violations.append(
            "L2: 내장 프리셋과 이름 충돌 — '%s' 은(는) 내장 이름(%s)이라 쓸 수 없음"
            % (name, ", ".join(sorted(BUILTIN_PRESETS)))
        )


def check_body(body, violations):
    n = len(body)
    if n > MAX_BODY_CHARS:
        violations.append(
            "L3: 본문 크기 초과 — 현재 %d자 > 상한 %d자" % (n, MAX_BODY_CHARS)
        )
    for lineno, line in enumerate(body.splitlines(), 1):
        for rx in FORBIDDEN_REGEXES:
            if rx.search(line):
                violations.append(
                    "L4: 금지 패턴 매치 (line %d): %s" % (lineno, line.strip())
                )
        for lit in FORBIDDEN_LITERALS:
            if lit in line:
                violations.append(
                    "L4: 내부 운영 경로/식별자 '%s' 언급 금지 (line %d): %s"
                    % (lit, lineno, line.strip())
                )
    if not _has_frontmatter_summary(body):
        violations.append(
            "L5: frontmatter `summary:` 1줄 필수 — 파일 선두 --- 블록 안에 "
            "`summary: <한 줄 소개>` 를 넣을 것"
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="커스텀 페르소나 프리셋 생성 lint (L1~L5)"
    )
    parser.add_argument("--name", required=True, help="프리셋 이름 (파일명이 될 값)")
    parser.add_argument(
        "--body-file", required=True, help="검사할 본문 파일 경로 (읽기 전용)"
    )
    args = parser.parse_args(argv)

    violations = []
    check_name(args.name, violations)

    body = None
    try:
        with open(args.body_file, "r", encoding="utf-8") as fh:
            body = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        violations.append("본문 파일을 읽을 수 없음 (%s): %s" % (args.body_file, exc))
    if body is not None:
        check_body(body, violations)

    # (P)∧¬(A) fence check on newline-PRESERVING bytes. `with open(..., "rb")`
    # closes the handle explicitly (no dangling fd); str.splitlines()/universal
    # newline read would hide CRLF / bare-CR / unicode-separator fences. Only run
    # when the main read succeeded (body is not None); a raw-read/decode failure
    # here is a race/TOCTOU and MUST fail-CLOSED — never silently skip the guard.
    if body is not None:
        raw_text = None
        raw_read_failed = False
        try:
            with open(args.body_file, "rb") as fh:
                raw_text = fh.read().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            raw_read_failed = True
        if raw_read_failed:
            violations.append(
                "L-FENCE: frontmatter 울타리(fence) 검사용 원본 읽기 실패 — "
                "fence 정합을 확인할 수 없어 거부 (fail-closed)"
            )
        elif _leading_fence_awk_mismatch(raw_text):
            violations.append(
                "L-FENCE: frontmatter 울타리(fence) 불일치 — 선두 `---` 가 hook awk "
                "기준 정확한 `---`(LF) 가 아님 (공백 padding / CR / 유니코드 라인 "
                "구분자). 정확히 `---` + LF 로 열 것"
            )

    if violations:
        for v in violations:
            print(v)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:  # traceback 금지 계약 — 이유만 출력하고 exit 1
        print("lint 내부 오류: %s" % exc)
        sys.exit(1)
