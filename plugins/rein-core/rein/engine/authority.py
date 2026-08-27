"""Capability 단위 authority 전환 계층 (plan Task 6.1 — spec §7 Migration
Plan, §49 이관 순서, Scope ID
`authority-switches-per-capability-with-dual-read-of-legacy-markers`).

spec §7 원문 인용(요지, 전환기 한정): "Capability 단위로 v2 authority 로
전환하며, 전환 구간에서 legacy marker 를 dual read 한다 (v2 evidence
우선)."

**Phase 7 웨이브 3 ③-d (2026-08-24) — legacy read 계층 전체 제거.** spec
§3.6 판정 상태표의 "legacy 제거 후 (종국)" 열이 이제 유일한 판정
경로다. 이 모듈은 더 이상 `trail/dod/` 하위의 어떤 legacy marker
파일(`.codex-reviewed`/`.security-reviewed`/`.review-pending`/
`dod-*.md`)도 읽지 않는다 — 그 marker 들을 정규화하던 함수
(`legacy_status`/`_legacy_code_review_status`/
`_legacy_security_review_status`/`_legacy_active_task_status`/
`_parse_codex_marker`/`_parse_stamp_field`/`_normalize_iso`)와 그 결과
타입(`LegacyStatus`, `LEGACY_PASS`/`LEGACY_FAIL`/`LEGACY_ABSENT`),
"legacy 가 최종값" 을 뜻하던 `SOURCE_LEGACY` 는 이번 웨이브로 코드에서
제거됐다. 아래 문서에서 "legacy 판정"/"dual read"/"legacy marker 로
대체" 를 서술하는 부분은 이 제거 이전(전환기)의 역사적 설명이며,
현재 코드에는 더 이상 대응하는 경로가 없다 — 재도입하려면 코드·주석
변경만으로는 부족하고 spec §3.6 자체의 재개정(수동 governance
acceptance)이 선행돼야 한다(이는 `DEFAULT_SWITCHED_CAPABILITIES`
재편입 조건과 동일한 성격의 제약이다).

이 모듈이 고정하는 계약 세 가지:

1. **전환 여부 조회** (`is_switched` / `load_authority_policy`) — capability
   가 v1 에서 v2 로 판정 권한을 넘겨받았는지는 정책이 결정한다. 프로젝트
   override 파일 `<project_root>/.rein/policy/authority.yaml` 이 있으면
   그것이 우선하고, 없으면 배포 기본값(`DEFAULT_SWITCHED_CAPABILITIES`
   — 이 모듈 내부 상수)을 쓴다. **Phase 7 결정 4(사용자 결정,
   2026-08-19)로 배포 기본값을 5종 전부에서 실배선 3종
   (code_review/security_review/active_task)으로 축소했다** — 이전
   (Task 6.1, 2026-08-12)의 5종 전부 결정은 폐기됐다. 사유: 남은 2종
   (tests_passed/user_approval)은 증거 발급 함수의 프로덕션 호출자가
   0건이고(당시 `legacy_status()` 도 이 두 축엔 항상 `LEGACY_ABSENT`
   를 반환했다 — 그 함수는 ③-d 로 제거됐고, 지금은 이 두 축의
   `v2_satisfied` 가 항상 evidence-존재 게이팅을 통과해야만 non-None
   이다, `rein.engine.evaluator._requirement_satisfied` 참조), 이 두
   축이 전환 상태에서 그 축을 요구하는 정책을 만나면 v2 evidence 가
   없는 한 `resolve_authority()` 가 항상 `satisfied=False` 를
   반환한다 — 그 요구를 실제로 발동시킬 판정부가 v1 에도 v2 에도 없는
   채 **영구 차단**되는 지뢰였다(실측 근거: Task 6.1 종결 기록
   `docs/reports/v2-phase-gates.md` "Task 6.1 종결" 절, 및 이
   저장소의 옛 dogfood override — 이 파일이 이미 3종만 전환하고
   있었다는 사실 자체가 그 지뢰를 우회하던 증거였다. 그 override 는
   기본값이 3종으로 좁혀지며 완전히 동일해져 2026-08-19 삭제됨).
   재편입 조건의 **정본은 spec §3.6 "전환 유예" 절**이다
   (`docs/specs/2026-08-07-rein-v2-governance-orchestration.md`) — 이
   docstring 은 그 복제 요약일 뿐이며, 재편입은 코드·주석 변경만으로
   할 수 없고 spec (iv) 의 수동 governance acceptance(증거 산출물
   3종: 게이트 대장 재편입 절 + spec 재검토 기록 + 활성 작업 정의서
   승인 라인) 후에만 수행한다. 요약: (a) 두 축의 실제 증거 발급 배선
   (`observe_test_run`/`issue_user_approval_evidence`) + 자격 검증 +
   닫힌 값 계약 2상태(subject-empty/subject-unresolved) 짝 테스트,
   (b) 보안 축에서 이미 관측된 D4 류 충돌(보수적 미충족 판정 + v2
   우선 원칙이 겹치면 통상 커밋까지 영구 차단될 수 있는 패턴) 해소. `plugins/rein-core/policies/` 는 governance policy 전용
   디렉토리이고 스키마가 `trigger/when/require/failure_mode` 로 닫혀
   있다(`kernel/policy.py`) — authority 전환 플래그는 그 스키마에 맞지
   않아 그 디렉토리에 파일을 두지 않는다(실측: `policies/` 바로 아래를
   `kernel.policy.load_policies` 로 스캔하면 이미 `tags.yaml` 과 스키마
   충돌이 나고, `tests/contract/test_default_policy_matrix.py` 의
   `DirectoryIsolationTest` 가 그 충돌 자체를 계약으로 고정하고 있다 —
   같은 디렉토리에 세 번째 스키마를 얹으면 그 테스트가 기대하는 에러
   메시지가 깨진다). override 파일은 `.rein/policy/` 아래 `testing.yaml`
   (`rein.capabilities.testing.capability.CONFIG_RELATIVE_PATH`)과
   동일한 패턴 — 디렉토리 전체를 스캔하지 않고 자기 이름의 파일 하나만
   읽으므로, 같은 디렉토리의 다른 v1 파일(`hooks.yaml`/`persona.yaml`/
   `rules.yaml`)이나 `testing.yaml` 과 공존해도 서로 간섭하지 않는다.
   override 파일 파싱은 `rein.kernel.yaml_subset` 의 D3 subset 파서를
   재사용하되(외부 YAML 라이브러리 의존 금지, py3.9 호환), 스키마 검증은
   `kernel/policy.py` 의 governance 4필드 검증기를 재사용하지 않는다 —
   authority 는 별개의 폐쇄 스키마(`switched` 필드 하나)를 이 모듈이
   직접 검증한다.

2. **결합 판정** (`resolve_authority`) — v2 판정(`v2_satisfied`, `bool`
   또는 `None`)을 최종 판정으로 삼는다(**legacy marker 대체는 ③-d 로
   완전히 제거됐다** — 아래가 지금의 유일한 규칙이다): 전환된
   capability 는 `v2_satisfied` 가 `bool` 이면 그 값이 그대로 최종
   판정이고 `source=SOURCE_V2` 다. `v2_satisfied` 가 `None` 이면
   "판정할 v2 재료가 없다"는 뜻이므로 **보수적으로 `satisfied=False`**
   로 판정하고 `source=SOURCE_NO_MATERIAL` 이다 — 예전에는 여기서
   legacy marker 를 조회해 대체했지만 지금은 그 조회 자체가 없다
   (fail-closed 방향 유지: "판정 재료 없음"이 조용히 통과로 새지
   않는다). 이 함수 자신은 `v2_satisfied` 가 왜 `bool`/`None` 인지
   모른다 — 그 이유는 호출자(`rein.engine.evaluator.
   _requirement_satisfied`)가 capability 판정 방식 분류(아래 2번
   항목의 `EVIDENCE_ISSUED_CAPABILITIES`/`FACT_JUDGED_CAPABILITIES`)에
   따라 결정한다. fact 판정형(active_task)은 등록 구현체가 있으면
   언제나 `bool` 을 넘긴다. 증거 발급형 중 code_review/security_review
   는 **2026-08-20 개정**(spec §3.6 판정 상태표, Phase 7 웨이브 3
   ③-a)으로 등록 구현체가 이미 종국 상태표(subject-empty→충족/
   subject-unresolved→미충족/non-empty+유효→충족/non-empty+무효→
   미충족)를 구현하므로 **③-d 부터는 항상** `bool` 을 넘긴다(이전에는
   이 계층이 subject 상태를 한 번 더 확인해 무효/부재 상황엔 `None`
   을 넘겼으나, 그 재확인은 legacy 대체 여부를 가르는 게이트였을
   뿐이었다 — legacy 자체가 사라진 지금은 불필요해 evaluator 에서
   제거됐다, 아래 `_requirement_satisfied` 참조). `None` 은 이제
   evidence-존재 게이팅을 그대로 유지하는 tests_passed/user_approval
   두 축이 실제로 전환됐을 때만 도달한다. 미전환 capability 는 이
   함수가 판정에 개입하지 않는다 — `intercepted=False`
   로 그 사실만 알리고 만다(호출자가 v1 경로를 그대로 따르라는 신호).

이 모듈은 engine 계층이다 — `rein.capabilities.*` 의 어떤 구현체도 import
하지 않는다(spec §3.1 §31/§4.1 capability 간 직접 의존 금지의 대칭 원칙:
engine 도 capability 구현을 직접 끌어오지 않는다). capability 이름은 항상
`rein.kernel.requirement.REQUIREMENT_NAMES` 문자열로만 다룬다 — v2
evidence 의 실제 계산(digest·policy version 결합, 종국 상태표 판정 등)은
다른 계층(engine/evaluator + 등록된 Requirement 구현체)의 소관이다. 이
모듈은 그 계산 결과(`bool` 또는 `None`)를 `v2_satisfied` 인자로 받아
위 2번 항목의 규칙 그대로 최종 판정에 쓸 뿐이다 — 호출자
(`rein.engine.evaluator._requirement_satisfied`)가 등록 구현체의
`evaluate(context)` 결과를 넘기거나(code_review/security_review/
active_task, 항상 `bool`), evidence 존재 여부로 게이팅한 값을 넘긴다
(tests_passed/user_approval, `bool` 또는 `None`).

실패 방향은 fail-closed 다: 정책 파일이 폐쇄 스키마를 벗어나면
`AuthorityPolicyError`, 고정 5종 밖 capability 이름을 조회하면
`UnknownCapabilityError` — 둘 다 조용히 통과(기본 미전환/기본 미충족
취급)시키지 않고 예외로 명시 실패한다.
"""
import os
import stat
from collections import namedtuple

from rein.kernel.requirement import (
    REQUIREMENT_NAMES,
    UnknownRequirementError,
    validate_requirement_names,
)
from rein.kernel.yaml_subset import YamlSubsetError, parse as _parse_yaml

# --- 최종 판정의 근거 라벨 ---
SOURCE_V2 = "v2"
# `v2_satisfied` 가 `None`(판정할 v2 재료 없음)일 때의 라벨 — ③-d 이전
# 에는 이 자리가 `SOURCE_LEGACY` 였다(legacy marker 로 대체). legacy
# read 계층 전체가 제거된 지금은 대체할 legacy 가 없으므로, 이 라벨은
# "legacy 로 대체됨"이 아니라 "판정 재료가 없어 보수적으로
# 미충족 처리됨"을 뜻한다(resolve_authority 참조).
SOURCE_NO_MATERIAL = "no_material"

# --- capability 판정 방식 분류 (Task 6.1 배선 재작업 — 부모 지시
# 2026-08-12, "증거 레코드 없음" ≠ "v2 가 판정을 못 내림") ---
#
# 5종 Requirement 는 판정 재료가 근본적으로 다른 두 부류로 갈린다:
#
# - **EVIDENCE_ISSUED_CAPABILITIES** (증거 발급형): `code_review`/
#   `security_review`/`tests_passed`/`user_approval`. Runtime 이 Evidence
#   레코드를 발급하고(`issue_*_evidence`), 등록 구현체는 그 레코드를
#   조회해 digest·policy version 등을 재결합해 판정한다. code_review/
#   security_review 는 등록 구현체가 종국 상태표를 이미 구현하므로
#   (`_requirement_satisfied` 참조, ③-d 부터) 항상 `bool` 을 넘긴다.
#   tests_passed/user_approval 은 여전히 "레코드 자체가 없으면
#   (`context.evidence_for(name)` 빈 tuple) v2 가 이 요구에 대해 아직
#   아무 것도 모른다"는 뜻으로 `None` 을 넘기는 게이팅을 유지한다(이
#   두 축은 이번 웨이브의 종국 상태표 개정 범위 밖 — `None` 은
#   `resolve_authority` 에서 legacy 대체가 아니라 보수적 미충족으로
#   판정된다, ③-d 이전에는 legacy marker dual read 의 대체 조건이었다).
# - **FACT_JUDGED_CAPABILITIES** (fact 판정형): `active_task`. Evidence
#   를 전혀 발급하지 않는다(`rein.capabilities.task.capability` 의
#   `ActiveTaskRequirement.evaluate` 는 `task.active`/
#   `changeset.task_relevant` 두 fact 만 본다 — 이 모듈은 그 구현을
#   import 하지 않고 이름만 안다, engine → capability 직접 의존 금지
#   원칙 유지). 이 부류는 "증거 레코드 없음"이 "v2 가 모름"을 뜻하지
#   않는다 — 등록 구현체가 실제로 평가를 수행했다면 그 결과가 곧 v2
#   판정이다. 배선부(`rein.engine.evaluator`)가 이 구분 없이 evidence
#   유무만으로 `None` 을 넘기면, 전환을 켜도 fact 판정형 capability 의
#   v2 판정이 (evidence 가 구조적으로 절대 존재하지 않으므로) 단 한
#   번도 쓰이지 못하고 매번 보수적 미충족(③-d 이전엔 legacy marker)
#   으로 대체되는 결함이 된다 — 실측(부모, 2026-08-12): 전환의 의미
#   자체가 사라지고, v2 가 "관련 없음"으로 올바르게 통과시켜야 할
#   상황에서도 그 판정이 쓰이지 못할 수 있다.
#
# 이 분류는 문자열 집합으로만 존재한다 — capability 구현을 import 하지
# 않는다(engine → capability 직접 의존 금지, spec §3.1 §31/§4.1). 분류의
# 유일한 SSOT 는 이 모듈이다 — 배선부는 `is_evidence_issued()` 를
# 조회만 하고 자체적으로 판단 로직을 복제하지 않는다.
EVIDENCE_ISSUED_CAPABILITIES = frozenset(
    ("code_review", "security_review", "tests_passed", "user_approval")
)
FACT_JUDGED_CAPABILITIES = frozenset(("active_task",))

# 로드 시점 불변식 — 5종 전부가 두 부류 중 정확히 하나에 속해야 한다.
# REQUIREMENT_NAMES 가 나중에 확장되는데 이 분류가 갱신되지 않으면, 새
# capability 가 조용히 어느 한쪽으로 흘러가는 대신 import 시점에 즉시
# 터진다 (드리프트 침묵 금지 — `rein.engine.evaluator` 의 FAILURE_MODES
# 드리프트 가드와 동일 원칙).
assert not (EVIDENCE_ISSUED_CAPABILITIES & FACT_JUDGED_CAPABILITIES), (
    "a capability cannot be both evidence-issued and fact-judged"
)
assert (EVIDENCE_ISSUED_CAPABILITIES | FACT_JUDGED_CAPABILITIES) == frozenset(
    REQUIREMENT_NAMES
), (
    "authority judgement-kind classification drifted from "
    "REQUIREMENT_NAMES — every capability must be classified as either "
    "evidence-issued or fact-judged"
)

# --- 정책 위치/기본값 ---
# 프로젝트 override 상대 경로 (Task 6.1 사용자 결정 2026-08-12). `.rein/
# policy/` 는 v1 파일(hooks.yaml/persona.yaml/rules.yaml)·testing.yaml
# 과 공존하는 디렉토리다 — 이 모듈은 그중 자기 이름의 파일 하나만 읽는다
# (디렉토리 스캔 없음, testing capability 의 CONFIG_RELATIVE_PATH 패턴과
# 동일).
PROJECT_POLICY_RELATIVE_PATH = os.path.join(".rein", "policy", "authority.yaml")

# 배포 기본값 — 별도 배포 파일이 아니라 이 모듈의 내부 상수다(위 모듈
# docstring 1번 항목 참조: governance policy 전용 `policies/` 디렉토리에
# 파일을 두면 그 디렉토리의 폐쇄 스키마 계약과 충돌한다). Phase 7 결정 4
# (사용자 결정, 2026-08-19) — 실배선 3종(code_review/security_review/
# active_task)만 기본 전환. 이전(Task 6.1, 2026-08-12)엔 5종 전부였으나,
# tests_passed/user_approval 은 증거 발급 경로가 프로덕션 호출자 0건이라
# (당시 legacy_status() 도 이 두 축엔 항상 LEGACY_ABSENT 를 반환했다 —
# 그 함수는 ③-d 로 제거됐다) 전환 상태로 두면 resolve_authority() 가
# 그 축을 요구하는 정책마다 v2 evidence 를 못 얻어(evidence 프로덕션
# 호출자 0건이므로) 항상 satisfied=False — 실제 판정부가 없는 채
# 영구 차단되는 지뢰였다(③-d 이후는 legacy 대체 자체가 없으므로 이
# 결론은 오히려 더 직접적으로 성립한다. 근거:
# docs/reports/v2-phase-gates.md "Task 6.1 종결" 절). `.rein/policy/
# authority.yaml`(이 저장소 dogfood override)이 이미 이 3종만 전환하고
# 있었다는 사실이 그 지뢰를 우회하던 증거였다 — 기본값이 이 3종으로
# 좁혀지며 그 override 파일은 기본값과 완전히 동일해져 2026-08-19
# 삭제됨(git history 참조, 삭제 사유는 이 상수의 변경과 동일 커밋).
# 재편입 조건의 정본 = spec §3.6 "전환 유예" 절 (이 주석은 복제 요약,
# 위 모듈 docstring 1번 항목과 동일): (a) 두 축의 발급 배선 + 자격
# 검증 + 2상태 짝 테스트, (b) 보안 축 D4 류 충돌 해소 — 충족 기록 +
# spec 재검토 + 사용자 승인(수동 acceptance, spec (iv)) 후에만 이
# 상수를 넓힌다. 하나만 충족하고 추가하면 제거한 지뢰가 재현된다.
DEFAULT_SWITCHED_CAPABILITIES = frozenset(
    ("code_review", "security_review", "active_task")
)

# 폐쇄 스키마 — authority.yaml 은 이 필드 하나뿐
_POLICY_FIELDS = ("switched",)

# 빈 전환 집합의 표현 (Medium 6-3, Phase 6 리뷰) — `rein.kernel.
# yaml_subset` D3 subset 문법은 빈 block sequence 를 표현할 방법이 없다:
# `switched:` 다음에 아무 항목도 없으면 "key expects an indented block or
# an inline scalar" 로 파싱 자체가 실패하고, flow style `switched: []` 도
# D3 가 명시 거부한다(`_REJECTED_SCALAR_PREFIXES` 의 `[`). 그 결과 "전부
# 미전환(v1 유지)" 상태를 authority.yaml 로 표현할 방법이 아예 없었다.
# `yaml_subset.py` 는 policy 로더(kernel/policy.py)·testing 설정 로더도
# 공유하는 범용 파서라 그 문법 자체를 확장하면 영향 범위가 이 모듈 밖
# 으로 번진다 — 대신 authority 자신의 폐쇄 스키마 안에서만 스칼라
# sentinel 값 하나를 예약한다: `switched: none` 은 정확히 이 문자열과
# 일치할 때만(대소문자·따옴표 무관, 관대한 보정 없음) 빈 frozenset 으로
# 해석된다. 다른 스칼라 문자열은 여전히 "list 여야 함" 오류로 거부된다
# (parse_authority_policy 참조).
_EMPTY_SWITCHED_SENTINEL = "none"

# (③-d 로 제거됨: legacy marker 파일명 상수 `_CODE_REVIEW_STAMP_NAME`/
# `_SECURITY_REVIEW_STAMP_NAME`/`_REVIEW_PENDING_NAME`, ISO 정규화 패턴
# `_ISO_PATTERN`, DoD/inbox 파일명 패턴 `_DOD_FILENAME_PATTERN`/
# `_INBOX_FILENAME_PATTERN` — 전부 legacy marker 를 읽던 함수 전용이었고
# 이 모듈은 더 이상 그 파일들을 읽지 않는다. `_DOD_FILENAME_PATTERN`/
# `_INBOX_FILENAME_PATTERN` 은 `rein.platform.task.facts` 에도 동명의
# 독립 상수가 있다 — 그쪽은 이 모듈을 import 하지 않는 별개 구현이라
# (spec §3.1 계층 분리) 이 제거로 영향받지 않는다.)


class AuthorityError(ValueError):
    """authority 판정 로드/평가 실패의 공통 base — fail-closed, 원인 명시."""


class AuthorityPolicyError(AuthorityError):
    """authority.yaml(배포 기본값 또는 프로젝트 override)이 폐쇄 스키마를
    벗어남 — 파일이 손상됐거나 읽을 수 없거나 미지 필드/미지 capability
    이름을 선언한 경우. 조용히 기본 미전환으로 fallback 하지 않는다."""


class UnknownCapabilityError(AuthorityError):
    """고정 5종(REQUIREMENT_NAMES) 밖의 capability 이름을 조회함.

    authority 계층은 v2.0 Runtime Contract 어휘 밖의 이름에 대해 판정을
    내릴 수 없다 — 조용히 "미전환"으로 넘기면 오타·상위 계층의 계약
    위반이 판정 누락으로 이어질 수 있으므로 명시 거부한다.
    """


class CapabilityClassificationError(AuthorityError):
    """capability 이름은 유효(REQUIREMENT_NAMES 원소)하나 판정 방식
    분류(EVIDENCE_ISSUED_CAPABILITIES/FACT_JUDGED_CAPABILITIES) 어느
    쪽에도 속하지 않음.

    이 상태는 모듈 로드 시점 assert 가 이미 막는다 — 두 분류의 합집합이
    REQUIREMENT_NAMES 와 어긋나면 import 자체가 실패한다. 그럼에도
    `is_evidence_issued()` 가 방어적으로 다시 검사하는 이유는 이 파일의
    반복 원칙과 같다: 유지보수 결함이 조용한 기본값으로 새지 않게 한다
    (`resolve_authority()` 말미의 `v2_satisfied` 타입 재검증과 동일
    패턴 — 로드 시점 assert 로 이미 막혀 있어도, 호출 경로에서 다시
    한 번 명시적으로 거부한다).
    """


def is_evidence_issued(capability):
    """capability 가 증거 발급형(EVIDENCE_ISSUED_CAPABILITIES)인지 — bool.

    이 질의가 판정 방식 분류의 유일한 조회 지점이다 — 호출자(배선부)는
    이 함수만 쓰고 `EVIDENCE_ISSUED_CAPABILITIES`/`FACT_JUDGED_CAPABILITIES`
    를 직접 참조해 자체 분기를 복제하지 않는다(분류 로직이 두 곳에
    흩어지지 않게).

    - 5종 밖 이름 → `UnknownCapabilityError`.
    - 유효하나 분류 누락(위 로드 시점 assert 가 이미 방지) →
      `CapabilityClassificationError` — 조용히 어느 한쪽으로 흘려보내지
      않는다.
    """
    _validate_capability_name(capability)
    if capability in EVIDENCE_ISSUED_CAPABILITIES:
        return True
    if capability in FACT_JUDGED_CAPABILITIES:
        return False
    raise CapabilityClassificationError(
        "{!r} is a known capability but is not classified as either "
        "evidence-issued or fact-judged — this is a maintenance gap, not "
        "a caller error".format(capability)
    )


# --- "현재 subject" fact 키 매핑 — 축 분류 판별자 (spec §3.6 판정
# 상태표, 2026-08-20 보강 Phase 7 웨이브 3 ③-a, ③-d 로 역할 축소) ---
#
# **③-d 갱신**: 이 딕셔너리는 이제 evaluator 에서 fact 값을 직접 조회하는
# 데 쓰이지 않는다 — `rein.engine.evaluator._requirement_satisfied()` 는
# 더 이상 "subject 가 non-empty digest 인지" 를 이 계층에서 재확인하지
# 않는다(등록 구현체가 종국 상태표를 이미 구현하므로 그 재확인이
# 불필요해졌다, `resolve_authority` docstring 참조). 남은 유일한
# 용도는 **축 분류 판별자**다 — `requirement in CURRENT_SUBJECT_FACT_KEYS`
# 로 "이 capability 는 종국 상태표 개정 대상(code_review/
# security_review)인가, 아니면 기존 evidence-존재 게이팅을 유지하는
# 축(tests_passed/user_approval)인가"를 evaluator 가 구분한다. 값(fact
# 키 문자열)은 각 capability 의 `evaluate()`(`rein.capabilities.review.
# capability.FACT_CHANGESET_REVIEW_DIGEST`/`rein.capabilities.security.
# capability.FACT_CHANGESET_SENSITIVE_DIGEST`)가 실제로 조회하는 값과의
# 대응 관계를 문서화하는 참고용으로 남긴다(import 로 결합하지 않고
# 값으로만 대응하는 기존 관례).
#
# 이번 웨이브는 code_review/security_review 2축만 포함한다 —
# tests_passed/user_approval 은 아직 이 매핑의 범위 밖이다(그 축의
# "현재 subject" 개념 자체가 이 웨이브의 설계 대상이 아니다, spec §3.6
# 전환 유예 절 — 두 축은 기본 authority 전환 목록에서도 제외돼 있다).
# 매핑에 없는 requirement 는 `evaluator._requirement_satisfied()` 가
# 기존 "evidence 레코드 존재" 게이팅으로 fallback 한다.
CURRENT_SUBJECT_FACT_KEYS = {
    "code_review": "changeset.review_digest",
    "security_review": "changeset.sensitive_digest",
}


# AuthorityResult: resolve_authority() 반환 계약.
#   intercepted=False — 미전환 capability. authority 가 판정에 개입하지
#     않았다 — satisfied/source 는 의미 없는 placeholder(None)이고,
#     호출자는 기존 v1 경로를 그대로 따라야 한다.
#   intercepted=True — 전환 capability. satisfied 가 최종 판정(bool),
#     source 는 그 판정이 v2 evidence 에서 왔는지(SOURCE_V2) 판정할
#     v2 재료 자체가 없어 보수적으로 미충족 처리됐는지
#     (SOURCE_NO_MATERIAL)를 밝힌다(③-d 이전에는 후자가 legacy marker
#     대체였다).
AuthorityResult = namedtuple(
    "AuthorityResult", ("intercepted", "satisfied", "source")
)


# ---------------------------------------------------------------------------
# 1. 전환 여부 — 정책 로드/조회


def parse_authority_policy(text, source):
    """authority policy 본문을 파싱해 전환된 capability 이름의 frozenset 반환.

    source 는 에러 메시지에 붙는 파일 경로/이름 (로드 시점 원인 명시 계약,
    kernel/policy.py 와 동일한 패턴).
    """
    try:
        document = _parse_yaml(text, source)
    except YamlSubsetError as error:
        raise AuthorityPolicyError(str(error))
    for key in document:
        if key not in _POLICY_FIELDS:
            raise AuthorityPolicyError(
                "{}: unsupported authority policy field {!r} (allowed: "
                "{})".format(source, key, ", ".join(_POLICY_FIELDS))
            )
    if "switched" not in document:
        raise AuthorityPolicyError(
            "{}: authority policy must declare 'switched'".format(source)
        )
    value = document["switched"]
    if value == _EMPTY_SWITCHED_SENTINEL:
        # 빈 전환 집합의 유일한 표현 (Medium 6-3 — 위 `_EMPTY_SWITCHED_
        # SENTINEL` 정의 참조). 이 분기는 `isinstance(value, list)` 검사
        # 보다 먼저 와야 한다 — 문자열은 list 가 아니므로 그대로 두면
        # 다음 줄에서 거부된다.
        return frozenset()
    if not isinstance(value, list):
        raise AuthorityPolicyError(
            "{}: field 'switched' must be a block sequence of capability "
            "names".format(source)
        )
    names = []
    for item in value:
        if not isinstance(item, str):
            raise AuthorityPolicyError(
                "{}: field 'switched' entries must be scalar capability "
                "names, got {!r}".format(source, item)
            )
        names.append(item)
    try:
        validated = validate_requirement_names(names, source=source)
    except UnknownRequirementError as error:
        # 호출자는 단일 예외 타입(AuthorityPolicyError)만 전제한다
        raise AuthorityPolicyError(str(error))
    if len(set(validated)) != len(validated):
        raise AuthorityPolicyError(
            "{}: field 'switched' has duplicate capability name(s): "
            "{}".format(source, ", ".join(validated))
        )
    return frozenset(validated)


def _load_policy_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as error:
        raise AuthorityPolicyError(
            "{}: unreadable authority policy file: {}".format(path, error)
        )
    return parse_authority_policy(text, source=path)


def load_authority_policy(project_root=None):
    """전환된 capability 집합을 로드한다 — 프로젝트 override 우선.

    `project_root` 가 주어지고 `<project_root>/.rein/policy/authority.yaml`
    이 존재하면 그 파일을 쓴다(디렉토리 스캔 없이 이 이름의 파일만 읽는다
    — 모듈 docstring 1번 항목 참조). 그렇지 않으면(project_root 가 None
    이거나 override 파일이 없으면) 배포 기본값(`DEFAULT_SWITCHED_CAPABILITIES`)
    을 쓴다. override 파일이 손상돼 있으면 `AuthorityPolicyError` 로
    fail-closed 한다 — 손상된 정책을 "미전환"으로 조용히 해석하지 않는다.

    경로가 존재하지만 **일반 파일이 아니면**(디렉터리·심볼릭 링크 등,
    Medium 6-2 + Phase 6 4회차 리뷰 High 2 시정) "파일 없음"으로 조용히
    fallback 하지 않는다 — 이전 구현은 `os.path.isfile()` 하나로 "읽을
    파일이 있다"와 "override 없음"을 합쳐 판정했는데, 그 결과 경로에
    디렉터리가 있어도(예: 실수로 `mkdir -p` 된 경우) `os.path.isfile()`
    이 False 를 반환해 override 가 부재하는 것처럼 배포 기본값으로
    흘러갔다 — 실제로는 프로젝트가 override 를 두려 한 흔적(그 경로에
    뭔가 존재함)이 있는데 손상으로 간주하지 않고 조용히 넘어간 것이다.

    **매달린 심볼릭 링크도 같은 함정의 다른 얼굴이다** (High 2, 리뷰어
    재현: `silently_defaulted 5`). 이전 구현은 `os.path.isfile()` 이전에
    `os.path.exists()` 로 "override 파일이 있는가"를 먼저 물었는데,
    `os.path.exists()` 는 심볼릭 링크를 따라간 뒤 그 **대상**이 존재하는지
    본다 — 링크가 매달려 있으면(대상이 없으면) `False` 를 반환한다. 그
    결과 "override 를 두려 한 흔적(경로에 뭔가 있다)"이 명백한데도 이
    함수는 override 가 아예 없는 것으로 오인해 배포 기본값(당시 5종
    전부 전환 — 현재는 3종, `DEFAULT_SWITCHED_CAPABILITIES` 주석 참조)
    으로 조용히 fallback 했다 — 정책 손상이 authority 의 적용 범위를
    오히려 넓히는 fail-open 이다(손상됐다고 배포 기본값 밖의 capability
    까지 v2 판정에 개입하면 안 된다 — 축소된 지금도 원리는 동일하다).

    수리: `os.path.exists()`/`os.path.isfile()`(둘 다 심볼릭 링크를
    따라간다) 대신 `os.lstat()`(링크를 따라가지 않는 stat)으로 그 경로
    자체의 종류를 확인한다 — 이 저장소의 다른 승인 소비 저장소
    (`rein.platform.storage.approval_store._reject_symlink_or_special`)
    가 이미 쓰는 것과 동일한 패턴이다. `FileNotFoundError`(ENOENT)만
    "진짜 부재"로 배포 기본값에 떨어진다 — 그 외 `OSError`(권한 거부 등
    "접근 불가")는 부재로 위장하지 않고 즉시 `AuthorityPolicyError` 로
    거부한다(approval_store 의 `_reject_symlink_or_special` 은 "아직
    없으니 새로 만들면 된다"는 다른 전제 위에 있어 모든 `OSError` 를
    부재로 흡수하지만, 이 함수는 무언가 새로 만들지 않으므로 접근 불가를
    부재로 흡수할 이유가 없다 — 오히려 "손상은 미전환으로 승격되지
    않는다"는 이 모듈의 반복 원칙에 맞춰 명시 거부하는 쪽이 안전하다).
    lstat 이 성공했는데 일반 파일이 아니면(심볼릭 링크 — 매달렸든
    유효하든 — 디렉터리·소켓 등 무엇이든) `AuthorityPolicyError` 로
    명시 거부한다.
    """
    if project_root:
        override_path = os.path.join(project_root, PROJECT_POLICY_RELATIVE_PATH)
        try:
            override_stat = os.lstat(override_path)
        except FileNotFoundError:
            override_stat = None
        except OSError as error:
            raise AuthorityPolicyError(
                "{}: authority policy path is inaccessible — refusing to "
                "silently fall back to the deployed default (fail-closed): "
                "{}".format(override_path, error)
            )
        if override_stat is not None:
            if not stat.S_ISREG(override_stat.st_mode):
                raise AuthorityPolicyError(
                    "{}: authority policy path exists but is not a "
                    "regular file (symlink — dangling or not — or other "
                    "special file rejected) — refusing to silently fall "
                    "back to the deployed default (fail-closed)".format(
                        override_path
                    )
                )
            return _load_policy_file(override_path)
    return DEFAULT_SWITCHED_CAPABILITIES


def is_switched(capability, switched=None, project_root=None):
    """capability 가 v2 authority 로 전환된 상태인지.

    `switched` 를 미리 로드한 frozenset 으로 주입하면 정책 파일을 다시
    읽지 않는다(호출 빈도가 높은 경로를 위한 캐시 주입 지점). 생략하면
    `load_authority_policy(project_root)` 를 호출한다.
    """
    _validate_capability_name(capability)
    if switched is None:
        switched = load_authority_policy(project_root=project_root)
    return capability in switched


def _validate_capability_name(capability):
    if capability not in REQUIREMENT_NAMES:
        raise UnknownCapabilityError(
            "{!r} is not a known capability — v2.0 authority only covers "
            "the fixed contract set {} (spec §3.4)".format(
                capability, REQUIREMENT_NAMES
            )
        )


# ---------------------------------------------------------------------------
# 2. 결합 판정 — v2 최종 판정 (③-d: legacy 대체 제거)


def resolve_authority(capability, v2_satisfied, project_root, switched=None):
    """capability 판정 — 전환 여부에 따라 v2 판정을 그대로 최종값으로
    삼는다 (spec §3.6 판정 상태표 "legacy 제거 후 (종국)" 열, 모듈
    docstring 2번 항목).

    **③-d 갱신 — legacy marker 대체는 완전히 제거됐다.** 이 함수는 더
    이상 `legacy_status()` 를 호출하지 않는다(그 함수 자체가 이번
    웨이브로 삭제됐다). 아래 규칙이 지금의 전부다.

    `v2_satisfied`: `bool` 또는 `None` — 그 외 타입은 명시 거부한다
    (Medium 6-1, 아래 참조).
      - `bool` = v2 가 이 requirement 에 대해 실제로 판정을 내렸다는
        뜻(등록 구현체의 `evaluate(context)` 결과, 또는 evidence 존재
        여부로 게이팅된 값). 그 값이 그대로 최종 판정이다
        (`source=SOURCE_V2`).
      - `None` = v2 가 판정할 재료를 갖지 못했다는 뜻(현재는
        tests_passed/user_approval 두 축의 evidence-존재 게이팅에서만
        발생한다 — 등록 구현체가 종국 상태표를 이미 구현하는
        code_review/security_review 는 `_compute_v2_satisfied` 가
        언제나 `bool` 을 계산하므로 이 경로에 도달하지 않는다, 아래
        `_requirement_satisfied` 참조). 이때는 **보수적으로
        `satisfied=False`** 로 판정한다(`source=SOURCE_NO_MATERIAL`)
        — legacy marker 를 조회해 대체하던 예전 경로는 없다.

    `switched` 를 주입하면 정책을 다시 로드하지 않는다(`is_switched` 와
    동일한 캐시 주입 지점).

    **폐쇄 입력 경계 — 관대한 truthy/falsy 강제 변환 금지** (Medium
    6-1, Phase 6 리뷰): 이전 구현은 `bool(v2_satisfied)` 로 무조건 강제
    변환했다 — 그 결과 문자열 `"false"`(비어있지 않은 문자열은 Python
    에서 항상 truthy) 가 `True` 로 승격되는 함정이 있었다. 이 함수는
    호출자(`evaluator._requirement_satisfied`)가 항상 `bool`/`None` 만
    넘긴다는 내부 계약에 의존하지 않는다 — 그 계약이 깨지면(예: 향후
    다른 호출자 추가, 리팩토링 실수) 조용히 오판정으로 새는 대신 여기서
    바로 명시 실패한다.
    """
    _validate_capability_name(capability)
    if v2_satisfied is not None and not isinstance(v2_satisfied, bool):
        raise AuthorityError(
            "v2_satisfied must be None or an actual bool, got {!r} (type "
            "{}) — this boundary does not coerce truthy/falsy values "
            "into bool (fail-closed)".format(
                v2_satisfied, type(v2_satisfied).__name__
            )
        )
    if switched is None:
        switched = load_authority_policy(project_root=project_root)
    if capability not in switched:
        return AuthorityResult(intercepted=False, satisfied=None, source=None)
    if v2_satisfied is not None:
        return AuthorityResult(
            intercepted=True, satisfied=v2_satisfied, source=SOURCE_V2
        )
    # v2 가 판정할 재료 자체가 없다 — 보수적으로 미충족. legacy marker
    # 대체는 없다(③-d 로 제거됨, 위 docstring 참조).
    return AuthorityResult(
        intercepted=True,
        satisfied=False,
        source=SOURCE_NO_MATERIAL,
    )
