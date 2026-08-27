"""bin/rein 진입 glue — stdin 이벤트 JSON 1건 → decision JSON 1건.

런타임 산출물 경로는 전부 환경변수로 받는다 — 저장소 트리에 파일을
남기지 않기 위한 계약 (plan Task 1.1).

## registry 배선 (Phase 6 Task 6.1 — v2 plan §7 이관 순서)

v2 capability 5종(`review`/`security`/`task`/`testing`/`approval`)은
각각 `register_*(registry)` 함수로 구현체를 명시 등록할 수 있게
Phase 3~5 에서 완성됐지만, 그 함수를 실제로 호출해 `runtime.evaluate`
에 registry 를 넘기는 프로덕션 코드가 이 파일 밖에 없었다 — 실측 결함
(테스트에서만 호출됨). `_build_registry()`가 그 배선을 담당한다:
5종 전부를 등록한 `RequirementRegistry` 를 만들어 반환하고, `run_event`
가 이를 `runtime.evaluate(..., registry=registry)` 에 전달한다. 이제
`evaluator._requirement_satisfied` 는 미등록 존재 검사 fallback 이 아니라
등록된 구현체의 `evaluate(context)` 로 판정을 위임한다(`rein/engine/
evaluator.py` 모듈 docstring "충족 판정" 절).

`_build_registry()`는 5종 등록만 한다 — capability 가 필요로 하는
fact(`changeset.digest`/`task.active`/`approval.consumption_store` 등)나
evidence_source 배선은 이 Task 의 범위 밖이다(오늘 `facts` 는 여전히
`tool`/`git.branch` 2개뿐, `evidence_source` 는 여전히 미지정 →
`NullEvidenceSource`). 그 fact/evidence 배선이 없는 한 등록된 각
구현체의 `evaluate()`는 필요한 fact 를 확보하지 못해 보수적으로
미충족(`False`)을 반환하므로(각 capability 모듈의 "확인 불가 ≠ 충족"
계약), 오늘 이 배선만으로는 실제 hook 판정 결과가 아직 달라지지
않는다 — 이 커밋은 "판정 인프라를 연결"하는 것이지 "판정 결과를
바꾸는" 것이 아니다. `tests/cli/test_run_event_registry_wiring.py`
가 registry 를 직접 다른 fact 조합으로 구동해(예: `active_task` 의
`task.active` fact) 등록된 구현체가 실제로 존재검사 fallback 과 다른
결과를 낼 수 있음을 행위 기반으로 고정한다.

## authority 배선 — project_root (Phase 6 Task 6.1 — spec §7 dual read)

`run_event()` 는 `REIN_PROJECT_ROOT` 환경변수를 읽어
`runtime.evaluate(..., project_root=...)` 에 그대로 넘긴다 — 기존
`REIN_POLICY_DIR`/`REIN_DB_PATH` 와 같은 스타일의 명시적 env 주입이다.
**cwd 로 추정하지 않는다** (`rein/cli/doctor.py::run_doctor` 는
`project_root` 미지정 시 `os.getcwd()` 로 fallback 하지만, 그 관례를
여기서는 의도적으로 따르지 않는다 — doctor 는 사람이 직접 부르는 진단
도구라 "지금 서 있는 디렉토리"가 자연스러운 기본값이지만, `run_event()`
는 hook 이 자동으로 부르는 판정 경로라 cwd 가 실제 프로젝트 루트와
다를 수 있고, 그 어긋남이 legacy marker 를 엉뚱한 트리에서 읽는 조용한
오판정으로 이어질 수 있다). 값이 없으면(환경변수 미설정 또는 빈
문자열) `project_root=None` 을 그대로 넘긴다 — `evaluator.evaluate()`
의 sentinel 계약(`PROJECT_ROOT_NOT_PROVIDED` 와 `None` 은 다른 의미,
`rein/engine/evaluator.py` 모듈 docstring 참조)에 따라, authority 는
적용되지 않되 그 사실이 Decision.reason 에 남는다(조용한 통과 금지 —
부모 지시). `hooks.json` 에서 실제로 이 환경변수를 채우는 배선(v1→v2
라우팅 전환)은 이 Task 의 범위 밖이다 — 오늘은 어떤 hook 도 이 값을
채우지 않으므로, 이 배선은 인프라만 연결한다(위 registry 절과 동일한
성격의 커밋).

## fact 배선 — command.type / changeset.digest / changeset.sensitive_digest
(Phase 6 Task 6.1 재작업, Medium 5 수리 — 독립 리뷰어 실증: registry 를
실배선해도 `facts` 가 여전히 `tool`/`git.branch` 2개뿐이면 등록된
구현체는 판단 재료가 없어 **항상** 보수적으로 미충족을 반환한다 —
"실배선"이 실제로는 활성화 불가 상태였다)

`_build_facts()` 가 `run_event()`/`run_explain()`(`rein/cli/explain.py`)
공유 진입점이다 — 두 함수가 서로 다른 fact 계산 경로를 타면 explain
의 "basis 3필드는 run_event 와 항상 같다" 계약(`explain.py` 모듈
docstring)이 다시 깨지므로(Medium 4 와 같은 부류의 재발), fact 구성
로직도 registry 구성과 동일하게 이 모듈 한 곳에만 둔다.

이미 존재하는 platform 구성요소만 재사용한다 (새 구현 없음):
- `command.type` — `rein.engine.command_classifier.classify()`. 이벤트의
  `tool == "Bash"` 이고 `payload["command"]` 가 비어있지 않은 문자열일
  때만 계산한다(그 밖의 tool 은 명령 문자열 자체가 없다). 이 fact 가
  없으면 `policies/default/*.yaml` 의 `when: command.type: git.*` 조건이
  단 한 번도 매칭되지 않는다 — 실측(이 수리 조사 과정에서 발견): 이
  fact 를 배선하기 전에는 `git commit` 이벤트조차 "no policy matched
  event" 로 항상 ALLOW 였다. registry/evidence_source 를 아무리 채워도
  policy 자체가 안 걸리면 그 아래 배선은 전부 죽은 코드였다.
- `changeset.digest` — `rein.platform.git.facts.worktree_changeset()` +
  `.changeset_digest()`. WORKTREE scope 를 쓴다(STAGED 가 아니라) —
  hook 이 관찰하는 "지금 이 순간의 변경"은 커밋 여부와 무관하게 작업
  트리 전체이고, 기존 `git.branch` fact 도 커밋 상태를 가정하지 않는다.
- `changeset.sensitive_digest` — 위 changeset 의 경로를
  `rein.engine.tags.classify_path()` (배포 기본 규칙,
  `load_tag_rules()`)로 필터링해 `sensitive` tag 경로만 남긴 뒤 같은
  `changeset_digest()` 로 재계산한다. 파일 필터링 후 동일 함수를
  재호출하는 것뿐 — 새 판정 로직이 아니다.

**비용 게이팅 — Phase 6 3회차 재리뷰 High 1 시정: 진짜 lazy 계산으로
전환** (spec §3.2). 이전(Phase 6 수리 워커 F/H)에는 이 함수가
`changeset.digest`/`changeset.sensitive_digest`/`changeset.tag` 값을
`_declared_requirements()`(trigger 만 보고 `when` 은 무시하는 근사 —
순환 의존을 피하려는 의도적 설계, 그 함수 docstring "순환 의존" 절)로
미리 계산해 값으로 채워 넣었다. 독립 리뷰어 3회차 실증: 배포 기본
policy 4개(`commit`/`push`/`push-testing`/`release`)가 전부 같은
trigger(`tool.pre`)를 공유하므로, 이 근사는 사실상 모든 tool 이벤트
(Edit/Write 같은 파일 편집 포함)에서 "declared 비어있지 않음"으로
판정해 changeset 전체를 해싱했다 — `when: command.type: git.commit`
같은 실제 매칭 조건은 전혀 보지 않았기 때문이다. 이 비용 게이팅은
훅 라우팅 전환의 선행 조건으로 지목됐다(저장소 계약
`fact-resolver-computes-only-policy-demanded-facts-once-per-cycle` 의
실효성 문제).

**수리**: 이 함수는 이제 이 3개 fact 를 전혀 계산하지 않는다 — 값이
아니라 **lazy resolver** 로 `_build_fact_resolvers()`(아래)가 별도로
구성해 `runtime.evaluate(..., fact_resolvers=...)`/`EvaluationContext`
에 전달한다(Phase 6 3회차 재리뷰로 `rein/engine/runtime.py` 가 이제
`fact_resolvers` 를 실제로 배선받는다, `rein/engine/runtime.py` 모듈
docstring 참조). 실제 계산은 매칭된 policy 의 `require:` 를 평가하는
capability 구현체가 `context.fact(key)` 를 호출할 때만 일어난다 —
capability 쪽은 이미 전부 `context.fact()` 로 조회하므로
(`rein/capabilities/*/capability.py`) 변경이 필요 없다. `task.active`/
`changeset.task_relevant`(아래 별도 절)는 이 워커의 대상이 아니다 —
배포 기본 policy 세트가 `active_task` 를 요구하지 않아 이 워커가
재현하는 실측 문제(파일 편집에서의 해싱)에 해당하지 않고, 두 fact 는
기존 `declared` 게이팅을 그대로 유지한다(`response["facts"]` 응답
투명성 계약, `tests/cli/test_run_event_over_blocking_regression.py` 를
건드리지 않기 위한 의도적 범위 축소 — 수리 보고서
`docs/reports/v2-phase6-cost-measurement.md` 에 명시).

**여전히 채우지 못한 fact — 추측으로 채우지 않는다** (수리 보고서에
명시 목록 별도 제공):
- `policy.version`/`policy.compatible_versions` — 이 저장소 어디에도
  "현재 policy version" 의 정의된 출처가 없다(config 파일도, 상수도,
  resolver 도 없음). 이 두 fact 가 없으면 code_review/security_review/
  tests_passed/user_approval **네 capability 전부**가 `evaluate()`
  최상단에서 항상 미충족을 반환한다 — 다른 모든 fact/evidence 를
  완벽히 채워도 이 결손 하나로 네 capability 모두 죽는다.
- `task.active`/`changeset.task_relevant` — v2 "활성 task" 개념 자체가
  아직 설계되지 않았다(v1 `trail/dod/*.md` 마커는 legacy dual read
  소관, `rein/engine/authority.py` 의 영역 — 이 fact 를 그 마커로
  채우면 authority 의 legacy 판정 로직을 fact 계층에서 중복 구현하는
  것이다).
- `changeset.tag` — 혼합 ChangeSet(서로 다른 tag 의 파일이 섞임)에는
  단일 값이 근본적으로 정의되지 않는다(`testing` capability 자신도
  이 이유로 혼합을 보수적으로 거부한다).
- `action.current` — "현재 action 식별자"가 무엇을 가리켜야 하는지
  정의가 없다.
- `approval.consumption_store` — `is_consumed`/`claim`/`release` 프로토콜
  구현체가 이 저장소 어디에도 없다(테스트 double 만 존재). 새로 만드는
  것은 "기존 구성요소 재사용" 범위를 벗어난다.

## evidence_source 를 의도적으로 배선하지 않는다 (안전성 판단 — 수리
보고서 핵심 발견)

`evidence_source` 를 `rein.platform.sqlite.store.LedgerVerifiedEvidenceSource`
로 채우는 것 자체는 기계적으로 쉽다. 하지만 **`policy.version` 이
채워지지 않은 채로 `evidence_source` 만 배선하면 기존보다 더 위험한
과차단을 새로 만든다**:

`rein/engine/evaluator.py::_requirement_satisfied` 의 authority 배선
경로(증거 발급형 capability)는 `evidence_present = bool(context.
evidence_for(requirement))` 로 "v2 가 이 요구를 아는가"를 판단한다.
`evidence_source` 가 `NullEvidenceSource`(현재 기본값)인 한
`evidence_present` 는 항상 `False` 이므로 `v2_for_authority = None` —
`rein/engine/authority.py::resolve_authority` 는 `v2_satisfied is None`
을 "v2 모름 → legacy marker 로 대체" 로 처리한다(안전한 경로, legacy
가 여전히 최종 판정을 낸다).

`evidence_source` 를 실제 ledger 로 바꾸면, 이 ledger 에 **단 하나의
v2 evidence 레코드라도** 존재하는 순간(같은 digest 든 아니든, 아직
policy.version 이 없어 유효성 판정 자체가 불가능한 상태에서도)
`evidence_present = True` 가 되고, `v2_for_authority = v2_satisfied`
(=`False`, `policy.version` 부재로 evaluate() 가 최상단에서 즉시
반환하는 값)가 된다. `v2_satisfied is not None` 이므로
`resolve_authority` 는 **legacy marker 를 조회조차 하지 않고 v2 의
`False` 를 그대로 최종 BLOCK 으로 확정한다** — legacy 표식이 실제로
PASS 여도 무시된다. 즉 evidence_source 단독 배선은 "v2 가 모른다(안전)"
상태를 "v2 가 안다고 착각하고 틀리게 판단한다(위험)"로 뒤집는다. 이
전환은 아직 ledger 가 비어 있는 오늘은 잠복해 있지만(한 번도 v2
evidence 가 발급된 적이 없으므로), 향후 어떤 경로로든 v2 evidence 가
한 건이라도 발급되는 순간 실제로 발화한다. 그래서 `policy.version`
이 채워지기 전까지는 `evidence_source` 를 의도적으로 미배선 상태로
둔다(수리 보고서의 재현 테스트가 이 판단을 증명한다).

## cold start 비용

`_build_registry()`는 `run_event` 와 동일하게 함수 내부에서 5개
capability 모듈을 lazy import 한다(spec §3.9 관례 유지 — 이 파일의
기존 모든 무거운 import 가 이미 이 패턴을 따른다). 실측
(`python3 -X importtime`, self-time 합산): 5개 capability 모듈 +
`RequirementRegistry` 를 새로 들여오는 데 드는 총 self-time 은
약 4.25ms(`hashlib`/`_blake2`/`_sha3` 체인이 `rein.kernel.evidence`
경유로 약 2.4ms 를 차지 — `review`/`security`/`approval` 3종이 공유해
1회만 지불된다, `shlex`/`rein.engine.tags`/`rein.kernel.changeset`
체인이 `testing` 전용으로 약 0.8ms). 이 중 `json` 하위 체인(약 0.87ms)
은 이미 `bin/rein` 최상위가 `import json` 을 해 둔 상태라 실제 hot
path 에서는 캐시 hit — 중복 비용이 없다. 즉 실측 순증가는 약 3.4ms 로,
인터프리터 기동 자체(수십 ms대)에 비해 무시할 수준이다. lazy import 를
top-level import 로 바꿔도 총 비용은 동일하다(어차피 매 프로세스
1회 지불) — lazy 를 유지하는 이유는 비용 절감이 아니라 기존 관례
일치 + `doctor`/`explain` 서브커맨드처럼 `run_event` 를 아예 타지
않는 경로가 이 비용을 지불하지 않게 하기 위해서다.

## 최종 조립 — 남은 4 fact + evidence_source 배선 (Phase 6 최종 조립
워커, spec §7)

위 절들이 배선한 것은 `command.type`/`changeset.digest`/
`changeset.sensitive_digest` 3개뿐이었다 — `policy.version`/
`task.active`/`changeset.task_relevant`/`changeset.tag`/
`action.current`/`approval.consumption_store` 6개 fact 와
`evidence_source` 자체는 여전히 미배선이었다(위 "여전히 채우지 못한
fact" 절, "evidence_source 를 의도적으로 배선하지 않는다" 절 참조).
`policies/default/_version.yaml` 이 생기고 `rein.kernel.policy.
load_policy_version()` 이 구현된 뒤에는 이 결손을 메울 수 있다 —
`policy.version` 이 채워지면 evidence 발급형 4종(code_review/
security_review/tests_passed/user_approval)의 validity 판정이 실제로
동작하고, 그래야 `evidence_source` 를 실 ledger 로 연결해도 위 절이
경고한 landmine(버전 축을 검증할 수 없어 아무 evidence 든 무조건
False 로 판정 → legacy PASS 를 부당하게 뒤집는 것)이 재발하지 않는다
— 유효한 v2 evidence 는 이제 실제로 True 를 낼 수 있고, 무효한(stale)
v2 evidence 만 legacy 를 정당하게 뒤집는다(그것이 애초에 authority
전환의 목적이다).

**비용 게이팅 전략 — "declared" 힌트** (`_declared_requirements`):
policy.version 이외의 새 fact 5종은 전부 I/O 를 동반한다(`task.active`
는 `os.listdir` 2회, `approval.consumption_store` 는 sqlite 연결
오픈). 매 hook 호출마다 무조건 계산하면 관련 capability 를 요구하는
policy 가 하나도 없는(오늘의 배포 기본 세트가 그렇다 — `active_task`/
`user_approval` 을 요구하는 기본 policy 가 없다) 압도적 다수의 호출에서
낭비다. `runtime.evaluate()`(이 워커의 scope 밖, 최소 변경만 허용)는
아직 `EvaluationContext` 의 lazy fact resolver 배선을 받지 않으므로
(위 "fact 배선" 절이 이미 이 제약을 명시함), 진짜 lazy 계산 대신 이미
로드된 `policies` 목록 중 **현재 이벤트의 trigger 와 일치하는 것만**
(`when` 매칭 여부는 여전히 무시 — Phase 6 마무리 수리 워커 H, `_declared_
requirements` docstring "순환 의존" 절)의 `require:` 절을 훑어 "이
capability 이름이 조금이라도 선언됐는가"만 빠르게 판정하는 보수적
근사를 쓴다 — 선언되지 않았으면 계산 자체를 생략하고, 선언됐으면
(trigger 는 맞지만) `when` 이 매칭되지 않을 이벤트에서도 계산한다
(과잉 계산 방향의 보수적 근사 — 과소 계산해서 실제로 필요한 fact 를
놓치는 것보다 안전하다). **trigger narrowing 의 정확도 경계**: 기본
배포 정책 세트(`policies/default/*.yaml`)는 4개 파일 전부가
`trigger: tool.pre` 를 공유하고, 모든 tool 이벤트(Bash/Edit/Write/
Read 등)는 tool 종류와 무관하게 항상 커널 이벤트 이름 `tool.pre` 로
정규화되므로(`rein/platform/claude/adapter.py` `HOOK_EVENT_NAMES` —
이 모듈은 그 native hook 이름 자체를 참조하지 않는다, spec §3.1 경계),
이 narrowing 은 그 4개 파일 사이에서는 아무것도 걸러내지 못한다 —
실질적 감소는 서로 다른 trigger(예: `task.completed`)를 쓰는 policy
가 함께 로드된 경우에만 발생한다. `policy.version` 자체는 파일 하나
읽기라 비용이
무시할 만해 이 게이팅을 적용하지 않는다 — `policy_dir` 이 있고 그
안에 `_version.yaml` 이 실제로 있을 때만 읽는다(파일 부재는 조용한
fact 부재로 흡수 — 아래 `_load_policy_version_fact` 참조. 반면
**파일이 존재하는데 내용이 손상**됐으면 `PolicyVersionError` 를 그대로
전파한다 — 삼키지 않는다. `tests/migration/test_authority_wiring.py`
의 여러 fixture 가 `_version.yaml` 자체를 두지 않은 최소 policy_dir
을 쓰므로, "파일이 아예 없음" 과 "파일이 있는데 손상됨" 을 다르게
취급하는 것은 그 기존 스위트를 깨지 않기 위한 요구사항이기도 하다).

**`changeset.task_relevant` 의 경로 소스 — git 아닌 이벤트는 git 을
부르지 않는다**: v1 `pre-edit-dod-gate.sh` 는 Edit/Write/MultiEdit
이벤트마다 딱 1개 파일(`tool_input.file_path`)만 봤다 — git 을 전혀
부르지 않았다. 이 fact 를 git WORKTREE changeset(이미 git.* Bash 명령
전용으로 계산됨)으로만 채우면 Edit 계열 이벤트에서는 영원히 채워지지
않는다(Edit 은 `command.type` 이 없다 — Bash 가 아니므로). 그래서 이
fact 의 경로 소스는 이벤트 종류에 따라 갈린다: Edit/Write/MultiEdit
이벤트는 `payload.file_path` 1개(v1 과 동일 비용, git 미호출),
git.* Bash 명령은 이미 계산된 WORKTREE changeset 의 경로 전체(중복
`git status` 호출 없음 — `_git_changeset_facts` 가 반환하는 paths 를
재사용). 그 밖의 이벤트(Read 등)는 관련성 판정 재료가 없으므로 fact
를 아예 채우지 않는다 — capability 자신이 `None` 을 "확인 불가 →
보수적으로 관련(True)" 으로 처리한다(spec §3.4).

**`approval.consumption_store` 의 직렬화 경계**: 이 fact 의 값은 sqlite
연결을 쥔 `ApprovalConsumptionStore` 객체다 — `decision["facts"]`/
`explanation["facts"]` 는 `bin/rein` 이 그대로 `json.dump` 하므로,
객체를 그대로 노출하면 직렬화가 깨진다(TypeError, 진단 도구가 통째로
죽는 사고). `_serializable_facts()` 가 응답 직전에 이 값을 `True`
(단순 존재 표시)로 치환한다 — 평가에 실제로 쓰인 `facts` dict 자체는
그대로 두고(객체를 참조로 들고 있어야 evaluate 후 close() 할 수 있다),
**응답용 사본**만 치환한다.

**evidence_source 연결**: `_build_evidence_source(project_root)` 가
`rein.platform.sqlite.store.LedgerVerifiedEvidenceSource` +
`rein.platform.storage.local.LocalStateRoot` 를 조합해 반환한다(기존
저장소 계층 재사용 — 새 저장 로직 없음). `project_root` 가 없으면
`None`(=`NullEvidenceSource`, 기존과 동일) — authority 배선이 이미
project_root 유무로 "적용/미적용" 을 가르는 것과 동일한 경계를 그대로
따른다(별도 판단 아님).
"""
import json
import os

ENV_POLICY_DIR = "REIN_POLICY_DIR"
ENV_DB_PATH = "REIN_DB_PATH"
ENV_PROJECT_ROOT = "REIN_PROJECT_ROOT"

FACT_TOOL = "tool"
FACT_GIT_BRANCH = "git.branch"
FACT_COMMAND_TYPE = "command.type"
FACT_CHANGESET_DIGEST = "changeset.digest"
FACT_CHANGESET_SENSITIVE_DIGEST = "changeset.sensitive_digest"

# code_review subject fact (spec §3.6 "리뷰 digest 범위" 절, 2026-08-20
# 보강, Phase 7 웨이브 3 ③-a) — `rein.platform.git.facts.review_digest()`
# 가 WORKTREE ChangeSet 에서 검토 면제 허용목록(문서/trail, 버전-only
# 특례는 미적용)을 제외해 산출한다. `rein.capabilities.review.capability.
# FACT_CHANGESET_REVIEW_DIGEST` 와 값이 반드시 같아야 한다 — 이 파일
# 고유 목적을 위한 로컬 재선언 관례를 그대로 따른다(기존 `FACT_
# CHANGESET_DIGEST` 등과 동일, 모듈 docstring "fact 배선" 절).
FACT_CHANGESET_REVIEW_DIGEST = "changeset.review_digest"

# 최종 조립 워커가 추가한 6개 fact 키 — 각 capability.py 의 동명
# `FACT_*` 상수가 정본이다(모듈 docstring "최종 조립" 절). capability
# 모듈을 import 하지 않고 로컬 리터럴로 재선언한다 — 기존 5개 fact 키도
# 이미 이 관례(로컬 재선언, import 하지 않음)를 따른다.
FACT_POLICY_VERSION = "policy.version"
FACT_POLICY_COMPATIBLE_VERSIONS = "policy.compatible_versions"
FACT_TASK_ACTIVE = "task.active"
FACT_CHANGESET_TASK_RELEVANT = "changeset.task_relevant"
FACT_CHANGESET_TAG = "changeset.tag"
FACT_ACTION_CURRENT = "action.current"
FACT_APPROVAL_CONSUMPTION_STORE = "approval.consumption_store"

# Phase 7 결정 1 (2026-08-19 사용자 결정, `dod-2026-08-19-v2-phase7-legacy.md`)
# 이 소비하는 fact 키 — `policies/default/commit.yaml`/`push.yaml` 의
# `when: task.exists: "true"` 조건화가 참조한다. 값은
# `rein.platform.task.facts.task_exists()` 가 그대로 낸다(v1
# `code-review-gate.sh` 의 `dod_exists` glob 술어를 그대로 미러링 —
# `task_facts.task_exists()` docstring 참조, `task.active` 스캐너와는
# 의도적으로 다른 의미론): 활성 작업이 있으면 리터럴 문자열 "true",
# 없으면 함수 반환값은 `None`(`FACT_TESTING_CONFIGURED` 와 동일한 "값
# 대신 부재" 계약). **배선부 문서 정합 수리(Phase 7 배선부)**: 이
# `None` 이 응답 facts dict 에서 항상 키 자체 부재로 나타나는 것은
# 아니다 — 아래 `_resolve_task_exists`/`_record` 가 실제로 조회되면
# `None` 을 그대로 기록하고, 그 값은 응답에 `"task.exists": null` 로
# 노출될 수 있다. policy `when:` 비교(`context.fact(key) != value`)는
# null 과 (한 번도 조회되지 않은) 부재를 동일하게 불일치 처리하므로
# 정책 매칭 결과는 어느 쪽이든 같다 — 보장되는 것은 매칭 실패이지 키
# 부재가 아니다. `task.active`(식별자 값)와는 별도 fact 다 — 이 정책
# 축은 식별자가 아니라 "존재 여부"만 필요하다.
FACT_TASK_EXISTS = "task.exists"

# Phase 6 수리 워커 F 가 추가 — `.rein/policy/testing.yaml` 존재 여부를
# 나타내는 fact 키. `policies/default/push-testing.yaml` 의 `when:
# testing.configured: "true"` 가 소비하는 계약 리터럴(High A, 모듈
# docstring 참조). 그 정책 파일 자신의 "fact 타입 계약" 주석과 동일하게
# 값은 항상 문자열 "true"(부재 = unconfigured) — kernel D3 파서가 YAML
# bool 자동 변환을 하지 않으므로 여기서도 Python bool 을 쓰지 않는다.
FACT_TESTING_CONFIGURED = "testing.configured"

# 4종 "증거 발급형" capability 이름 — `rein.engine.authority.
# EVIDENCE_ISSUED_CAPABILITIES` 와 값이 같지만(둘 다 code_review/
# security_review/tests_passed/user_approval), 이 상수는 이 파일 고유
# 목적(아래 두 게이팅) 을 위해 로컬로 재선언한다 — authority 는 engine
# 계층이고 "누가 이 fact 를 필요로 하는가"는 authority 의 관심사가
# 아니라 이 fact 배선 계층의 관심사이기 때문이다(다른 이유로 우연히
# 같은 4개 이름이 나온 것 — engine import 로 결합시키지 않는다, 위
# _REQUIREMENT_* 상수와 동일 관례).
#
# 이 상수가 게이팅하는 두 가지(Phase 6 수리 워커 F, 독립 리뷰어 Medium
# B/D 지적):
# 1. **changeset digest 류 계산 여부** — 각 capability 모듈이 실제로
#    소비하는 fact 를 확인했다(grep 실측): code_review 는 `changeset.
#    review_digest`(spec §3.6 "리뷰 digest 범위" 절, 2026-08-20 보강 —
#    이전엔 `changeset.digest` 를 썼으나 Phase 7 웨이브 3 ③-a 에서
#    전환), tests_passed/user_approval 은 여전히 `changeset.digest`,
#    security_review 는 `changeset.sensitive_digest`, tests_passed 는
#    추가로 `changeset.tag` 도 쓴다. 넷 다 이 fact 류 없이는 evaluate() 가
#    fact 확인 단계에서 즉시 미충족을 반환한다 — 이 넷 중 하나라도
#    declared 면 계산한다(이전처럼 `command.type` 이 `git.` 로 시작하는지
#    를 보지 않는다 — 그 게이팅은 두 방향 모두 틀렸다: git.* 명령인데
#    이 넷 중 아무 것도 declared 가 아니면 낭비였고, git 이 아닌 명령의
#    정책이 이 넷 중 하나를 요구하면 영원히 계산되지 않아 그 capability
#    가 항상 미충족이었다).
# 2. **버전 파일 부재 경계** — `_load_policy_version_fact` 가 이 넷 중
#    하나라도 declared 인데 버전 파일 자체가 없으면 "미설정"으로 조용히
#    넘기지 않고 설정 오류로 차단한다(Medium D — 넷 다 policy.version
#    fact 없이는 v2 evaluate() 가 항상 False 를 내고, 그 False 가
#    evidence_present=True 상황에서 legacy PASS 를 부당하게 뒤집는
#    landmine 을 policy.version 부재만으로 재점화하기 때문이다).
#
# `_declared_requirements()` 와 동일한 보수적 근사를 그대로 재사용한다
# — 현재 이벤트의 trigger 와 일치하는 policy 만 보고(Phase 6 마무리
# 수리 워커 H), 그 안에서는 `when` 매칭을 보지 않고 "이 capability 를
# 요구하는 policy 가 존재하는가"만 본다(과잉 계산 방향의 보수적 근사,
# `_declared_requirements` 자신의 docstring 참조 — 여기서도 동일한
# 트레이드오프를 그대로 받아들인다).
_EVIDENCE_ISSUED_REQUIREMENTS = frozenset(
    ("code_review", "security_review", "tests_passed", "user_approval")
)

# `changeset.task_relevant` 의 경로 소스로 단일 대상 파일을 쓰는 tool —
# v1 `pre-edit-dod-gate.sh` 의 matcher(`Edit|Write|MultiEdit`)와 동일
# (모듈 docstring "changeset.task_relevant 의 경로 소스" 절).
_TASK_RELEVANT_EDIT_TOOLS = frozenset(("Edit", "Write", "MultiEdit"))


def _build_registry():
    """v2 capability 5종을 등록한 RequirementRegistry 를 구성해 반환한다.

    등록 순서는 계약상 무의미하다(`RequirementRegistry.register` 는
    이름 기반 dict 등록이라 순서에 의존하지 않는다) — v2 plan §7 이관
    순서(code_review → security_review → active_task → tests_passed →
    user_approval)를 코드 순서로 그대로 두면 읽기 좋다.

    매 호출마다 새 `RequirementRegistry` 인스턴스를 만든다 — capability
    구현체(`*Requirement` 클래스) 자체는 상태를 갖지 않는 순수
    `evaluate(context)` 이므로 재사용해도 판정 결과는 같지만(테스트
    계약, `tests/cli/test_run_event_registry_wiring.py`), 매번 새로
    만들면 어떤 구현체가 실수로 인스턴스 상태를 갖게 되더라도 cycle
    간에 새지 않는다 — 그리고 `RequirementRegistry.register` 는 같은
    인스턴스에 중복 등록을 거부하므로(모듈 재사용 시 두 번째 호출이
    깨짐), 매 호출 새 인스턴스가 애초에 유일하게 안전한 형태다.
    """
    from rein.capabilities.approval.capability import register_user_approval
    from rein.capabilities.review.capability import register_code_review
    from rein.capabilities.security.capability import (
        register_security_review,
    )
    from rein.capabilities.task.capability import register_active_task
    from rein.capabilities.testing.capability import register_tests_passed
    from rein.engine.registry import RequirementRegistry

    registry = RequirementRegistry()
    register_code_review(registry)
    register_security_review(registry)
    register_active_task(registry)
    register_tests_passed(registry)
    register_user_approval(registry)
    return registry


def _git_changeset_facts(project_root):
    """WORKTREE changeset 의 digest/sensitive_digest/tag/paths 를 함께 계산한다.

    기존 platform 함수(`rein.platform.git.facts`)와 tag 분류기
    (`rein.engine.tags`)를 조합만 할 뿐 새 판정 로직은 없다(모듈
    docstring "fact 배선" 절). `tag_rules.load_tag_rules()` 는 1회만
    호출해 sensitive-path 필터링과 `changeset.tag` 분류 양쪽에 재사용한다
    (비용 관리 — 같은 작은 YAML 파일을 두 번 읽지 않는다). 해석 불가
    (레포 부재 등)는 전부 `None` — fact 부재로 흡수한다(기존
    `current_branch`/`worktree_changeset` 관례와 동일, 평가 실패로
    승격하지 않는다). `ContentSizeExceededError` 류는 여기서 잡지 않고
    그대로 전파한다 — `run_event()` 호출부는 `bin/rein` 의 포괄 예외
    처리기가 BLOCK + exit 0 로 fail-closed 매핑하고(모듈 docstring
    참조), `run_explain()` 호출부는 진단 도구의 "예외를 흡수하지 않는다"
    계약(`bin/rein` 모듈 docstring)을 그대로 따른다.

    반환: `(digest, sensitive_digest, tag, paths, review_digest)`
    5-tuple. `paths` 는 이 WORKTREE changeset 의 전체 경로 tuple(호출자가
    `changeset.task_relevant` 계산에 재사용 — git 명령 이벤트에서
    changeset 을 다시 계산하지 않기 위함, 모듈 docstring "changeset.
    task_relevant 의 경로 소스" 절) 또는 changeset 자체가 해석 불가면
    `None`. `review_digest` 는 맨 끝에 추가됐다(Phase 7 웨이브 3 ③-a) —
    기존 4-tuple 소비처(`_compute()[0]`/`[1]`/`[2]`/`[3]`)의 인덱스를
    보존하기 위해 append 방식을 택했다(기존 위치를 바꾸면 그 소비처
    전부를 다시 훑어야 한다 — 최소 침습).

    `sensitive_digest`(D4 해소, spec §3.6 "digest scope 프로필" 절,
    2026-08-19) — 이 함수는 `digest_scope: sensitive`(기본) 프로필
    전용 산정이다(WORKTREE 기준, 기존 의미론 그대로) — `strict` 프로필은
    이 함수를 쓰지 않고 `_build_fact_resolvers()` 가 별도로
    `rein.platform.git.facts.strict_security_digest()`(STAGED 기준)를
    직접 호출한다(아래 `_resolve_sensitive_digest` 참조) — 두 프로필이
    서로 다른 scope(WORKTREE vs STAGED)를 쓰므로 이 함수 하나로 통합하지
    않는다. 이 함수가 내는 `sensitive_digest` 는 이제 닫힌 값 계약
    2상태를 포함한 세 형태 중 하나다: WORKTREE changeset 자체가 해석
    불가(레포 부재 등)면 `SUBJECT_UNRESOLVED`(이전에는 `None` —
    "부재"와 "확인했더니 0건"을 구분하지 못해 `SecurityReviewRequirement.
    evaluate()` 가 둘 다 미충족으로 뭉뚱그렸다, D4 지뢰), sensitive 경로
    분류 결과가 0건이면 `SUBJECT_EMPTY`(이전에는 `None`), 그 부분집합의
    digest 계산 자체가 실패하면(예: 저장소 toplevel 조회 실패)
    `SUBJECT_UNRESOLVED`, 그 외에는 실제 content digest 문자열이다.

    `review_digest`(code_review subject, spec §3.6 "리뷰 digest 범위"
    절, 2026-08-20 보강, Phase 7 웨이브 3 ③-a) — WORKTREE changeset 에서
    검토 면제 허용목록(문서/trail, 버전-only 특례 미적용)을 제외한
    집합의 digest 다. 계산은 `rein.platform.git.facts.review_digest()`
    에 이미 계산된 `changeset`(WORKTREE)을 그대로 넘겨 위임한다 —
    `git status` 를 다시 실행하지 않는다(이 함수 자신의 "단일 pass"
    계약, 위 docstring "review_digest" 항목). WORKTREE changeset 자체가
    해석 불가면 `SUBJECT_UNRESOLVED`, 그 밖의 닫힌 값 2상태·실제
    digest 문자열은 `rein.platform.git.facts.review_digest()` docstring
    참조.

    `digest`/`tag`(index 0/2)는 이 워커의 범위 밖 — 기존 "부재는 None"
    관례를 그대로 유지한다(그 두 fact 는 D4/리뷰 digest 대상이 아니다,
    tests_passed 등 다른 capability 소관).
    """
    from rein.engine import tags as tag_rules
    from rein.kernel.changeset import SUBJECT_UNRESOLVED
    from rein.platform.git import facts as git_changeset_facts

    changeset = git_changeset_facts.worktree_changeset(cwd=project_root)
    if changeset is None:
        return None, SUBJECT_UNRESOLVED, None, None, SUBJECT_UNRESOLVED
    digest = git_changeset_facts.changeset_digest(changeset, cwd=project_root)

    rules = tag_rules.load_tag_rules()
    # Phase 7 웨이브 3 ③-a 리팩토링 — sensitive 경로 필터링 + digest 계산은
    # 더 이상 여기서 인라인으로 반복하지 않는다. `rein.platform.git.facts.
    # sensitive_security_digest()`(review_digest()/strict_security_subject()
    # 와 동일한 위치의 단일 정본)로 끌어올려, `--print-subject security_
    # review`(sensitive 분기, `rein.cli.issue_evidence.print_subject()`)가
    # 같은 함수를 거치게 한다 — 이 코드 경로와 그 CLI 표면이 서로 다른
    # 판정을 낼 수 없다(발산 금지). `ChangeSet`/`SCOPE_WORKTREE`/
    # `SUBJECT_EMPTY` 는 그 계산이 옮겨가며 이 함수에서 더 이상 쓰이지
    # 않게 됐으므로 로컬 import 에서도 함께 제거했다 — `SUBJECT_UNRESOLVED`
    # 만 조기 반환 분기에 여전히 필요하다.
    sensitive_digest = git_changeset_facts.sensitive_security_digest(
        changeset, cwd=project_root, tag_rules=rules
    )
    tag = git_changeset_facts.changeset_tag(changeset, tag_rules=rules)
    review_digest_value = git_changeset_facts.review_digest(
        changeset, cwd=project_root
    )
    return digest, sensitive_digest, tag, changeset.paths, review_digest_value


_NO_CACHED_POLICY_VERSION_ARG = object()


def _security_digest_scope_profile(
    policy_dir, cached_policy_version=_NO_CACHED_POLICY_VERSION_ARG
):
    """`policy_dir` 버전 선언의 `digest_scope` 프로필을 읽는다 (spec §3.6).

    `_build_fact_resolvers()` 의 `_resolve_sensitive_digest` 가 이 값으로
    WORKTREE 기준 sensitive 분류(`sensitive`, 기본)와 STAGED 기준
    허용목록 산정(`strict`) 중 무엇을 쓸지 고른다.

    **git 상태·수명주기 판정으로 위임 (2026-08-20 보강)** — 실제 판정은
    `rein.platform.git.facts.resolve_policy_version_digest_scope()` 가
    한다(spec §3.6 "선언의 유효 기준" 절, s1~s5 + malformed 교차 m1~m3).
    이 함수는 `policy_dir` 미설정(None/빈 값)만 짧게 흡수해 `DIGEST_SCOPE_
    SENSITIVE` 로 돌려주고, 그 밖은 전부 위임한다 — **더 이상 `os.path.
    exists()` 로 "파일 있음/없음"만 보지 않는다**: git 저장소 + 추적
    상태에서는 미커밋 worktree 편집이 유효 선언에 개입하지 못하고
    (`s3`/`m1`/`m3` 는 `PolicyVersionGitStateError` 로 명시 실패,
    `s4`untracked 는 경고와 함께 "선언 없음"으로 흡수), git 이 아니거나
    (`s5`) `policy_dir`/`_version.yaml` 자체가 없으면 기존과 동일한
    worktree 직접 로드 경로로 떨어진다(하위호환 — 기존 fixture 다수가
    `policy_dir` 을 git 저장소 밖에 둔다).

    `cached_policy_version`(선택) — `_resolve_sensitive_digest` 의 캐시
    공유 경로(`policy_version_cache`)가 전달하는 `_load_policy_version_
    fact()` 결과를 그대로 통과시킨다. `facts.resolve_policy_version_
    digest_scope()` 가 **s5(비 git 문맥)에 한해서만** 이 힌트를 재사용해
    `_version.yaml` 을 두 번 읽지 않는다 — git 추적 컨텍스트에서는 이
    힌트를 신뢰하지 않고 항상 새로 판정한다(캐시된 값은 naive worktree
    읽기의 산물이라 이 함수가 고치는 결함을 재도입하게 되므로). 이
    함수가 직접 호출될 때(기본값, 하위호환)는 힌트 없이 위임한다.
    """
    from rein.kernel.policy import DIGEST_SCOPE_SENSITIVE
    from rein.platform.git.facts import resolve_policy_version_digest_scope

    if not policy_dir:
        return DIGEST_SCOPE_SENSITIVE
    if cached_policy_version is _NO_CACHED_POLICY_VERSION_ARG:
        return resolve_policy_version_digest_scope(policy_dir)
    return resolve_policy_version_digest_scope(
        policy_dir, cached_policy_version=cached_policy_version
    )


def _build_fact_resolvers(
    event,
    project_root,
    policy_dir=None,
    read_only=False,
    resolved_out=None,
    opened_approval_store=None,
    policy_version_cache=None,
):
    """expensive/trigger-only-근사 fact 전체의 lazy resolver 를 등록해
    반환한다 (Phase 6 3회차 재리뷰 High 1 이 changeset 해시 3종으로
    시작한 lazy 전환을, Phase 6 4회차 독립 리뷰 Medium 1 이 나머지
    (`task.active`/`changeset.task_relevant`/`action.current`/
    `approval.consumption_store`)까지 같은 구조로 확장한다 — spec
    §3.2, `rein/engine/runtime.py` 모듈 docstring "fact_resolvers 배선"
    절).

    `project_root` 가 없으면(None/빈 문자열) `None` 을 반환한다 — 이
    함수를 호출하지 않는 것과 동일한 효과(`EvaluationContext(fact_
    resolvers=None)`)이고, `_build_facts()`/`_build_evidence_source()`
    가 이미 project_root 유무로 "적용/미적용"을 가르는 것과 같은 경계다
    (모듈 docstring "authority 배선" 절).

    **값이 아니라 resolver 를 등록한다** — 실제 계산은
    `EvaluationContext.fact(key)` 가 처음 조회될 때만 일어난다(매칭된
    policy 의 `require:` 를 평가하는 capability 구현체가 그 fact 를
    실제로 조회할 때뿐, `rein/capabilities/*/capability.py`, 변경 없음).

    ## `policy_dir` — security_review digest scope 프로필 선택 (spec §3.6,
    2026-08-19)

    `changeset.sensitive_digest` resolver(`_resolve_sensitive_digest`)는
    `policy_dir`(선택, 기본 `None`)로 `_security_digest_scope_profile()`
    을 조회해 `strict` 프로필이면 `rein.platform.git.facts.
    strict_security_digest()`(**STAGED** 기준 — 커밋 판정 시점에
    "지금 커밋될 것"을 검토 대상으로 삼는다는 spec §3.6 계약)를 직접
    호출하고, `sensitive`(기본 프로필)면 기존과 동일하게
    `_git_changeset_facts()`(**WORKTREE** 기준, 다른 세 fact —
    `changeset.digest`/`changeset.tag`/paths — 와 같은 계산에서 나온
    값)의 결과를 재사용한다. 두 프로필이 서로 다른 Enforcement Scope
    (STAGED vs WORKTREE)를 쓰는 것은 의도된 이원화다 — `strict` 는
    본 저장소처럼 "커밋될 변경 전체를 검토"해야 하는 세트가 선언하고,
    `sensitive`(사용자 프로젝트 기본값)는 v1 이래의 "민감 경로만
    표적화"하는 WORKTREE 관찰을 그대로 유지한다(과차단 방지). `policy_dir`
    미지정 호출자(하위호환)는 항상 `sensitive` 로 흡수된다(`_security_
    digest_scope_profile(None)` 계약).

    ## `policy_version_cache` — 같은 cycle 안 policy version 이중 읽기 제거

    `_security_digest_scope_profile(policy_dir)` 는 그 자체로 `load_
    policy_version(policy_dir)` 을 다시 호출한다 — 그런데 `_build_facts()`
    가 같은 cycle 에서 `policy.version` fact 를 채우려고 이미 한 번
    `_load_policy_version_fact()` 로 같은 파일을 읽었다(그 함수 내부에서
    `load_policy_version()` 호출). `security_review` 가 declared 인
    cycle 에서 `changeset.sensitive_digest` 가 실제로 조회되면, 결과적으로
    같은 `_version.yaml` 을 한 cycle 안에서 두 번 읽는 중복이 생긴다.

    `policy_version_cache`(선택, 기본 `None`) — 호출자가 `_build_facts()`
    에 넘긴 것과 **같은 빈 list 참조**를 여기도 함께 넘기면(`_evaluate_
    event()` 본문 참조), `_build_facts()` 가 이미 append 해 둔 값(로드된
    `PolicyVersion` 또는 `None` — 버전 파일이 실재하지 않아 `_load_
    policy_version_fact()` 가 `None` 을 반환한 경우도 포함)을 `_resolve_
    sensitive_digest` 가 그대로 재사용한다 — `_security_digest_scope_
    profile()` 재호출(=`load_policy_version()` 재호출)을 생략한다.
    캐시가 `None` 을 담고 있으면(버전 파일 부재) `_security_digest_scope_
    profile(None)` 과 동일하게 `DIGEST_SCOPE_SENSITIVE` 로 흡수한다 —
    새 판단을 추가하지 않고 기존 계약을 캐시 경로에도 그대로 반영할
    뿐이다. `policy_version_cache` 가 `None`(기본)이거나 빈 list 면(예:
    `policy_dir` 없이 호출됐거나, 기존 직접 호출자가 이 인자를 아예
    모르는 하위호환 경로) 기존과 동일하게 매번 `_security_digest_scope_
    profile(policy_dir)` 을 호출한다 — 동작 자체는 이전과 한 글자도
    다르지 않고, 중복 I/O 만 제거된다.

    ## Medium 1 (Phase 6 4회차 독립 리뷰) — trigger-only 근사의 잔여 결함

    changeset 해시 3종은 위 High 1 수리로 진짜 lazy 가 됐지만,
    `task.active`/`changeset.task_relevant`(구 `_build_facts()` 의
    `_REQUIREMENT_ACTIVE_TASK in declared` 분기)와 `action.current`/
    `approval.consumption_store`(구 `_REQUIREMENT_USER_APPROVAL in
    declared` 분기)는 여전히 `_declared_requirements()`(trigger 만
    보고 `when` 은 무시하는 근사, "확인 불가" 아니라 "과잉 계산" 방향의
    보수적 근사)로 게이팅되는 **값**으로 `_build_facts()` 안에서 즉시
    계산됐다. 독립 리뷰어 재현: `when: command.type: git.commit` 인
    `active_task` policy 를 로드한 상태에서 파일 편집(Edit) 이벤트를
    평가해도 — `command.type` fact 자체가 없어 그 policy 는 실제로는
    한 번도 매칭되지 않는데도 — `task_active_identifier()`(`os.listdir`
    2회 I/O)가 1회 실행됐다. changeset 해시 축에서 이미 입증된 것과
    똑같은 결함이 이 두 requirement 축에도 그대로 남아 있었다.

    **수리**: 이 네 fact 도 changeset 해시와 완전히 같은 메커니즘으로
    옮긴다 — 새 캐싱/게이팅 방식을 발명하지 않는다. `task.active`/
    `changeset.task_relevant`(git.* 명령 이벤트에서 경로가 필요한 경우)
    는 changeset 해시 3종과 같은 `_compute()` closure 캐시를 공유한다
    (아래 "cycle 당 1회 계산 보장" 절 — 이 공유가 없으면 `active_task`
    가 declared 인 git 명령 이벤트에서 `_git_changeset_facts()` 가
    changeset 축과 task_relevant 축에서 각각 별도로 불릴 수 있다).
    `action.current` 는 I/O 가 없는 순수 계산이라 `FACT_COST_CHEAP` 로
    등록한다(다른 셋은 `FACT_COST_EXPENSIVE`) — cost 는 순수 메타데이터
    일 뿐 두 등급 모두 동일하게 lazy 하다(`rein/engine/context.py` 모듈
    docstring "Lazy Fact Resolution" 절).

    ## 응답 투명성 — `resolved_out`

    `_build_facts()` 는 더 이상 이 네 fact 를 값으로 갖지 않으므로,
    `run_event()`/`run_explain()` 이 예전처럼 `_build_facts()` 의 반환
    dict 만 가지고 `decision["facts"]`/`explanation["facts"]` 응답을
    구성하면 실제로 계산된 값이 응답에서 사라진다 —
    `tests/cli/test_run_event_over_blocking_regression.py` 가 이미
    `response["facts"].get("task.active")` 등을 검증하는 응답 투명성
    계약을 갖고 있었다(이 fact 들이 changeset 해시처럼 "응답에 노출 안
    해도 되는" 부류가 아니었다는 뜻). `resolved_out` 이 이 문제를
    푼다 — 값이 아니라 **dict(선택, 기본 `None`)**: 호출자가 넘기면,
    이 네 resolver 는 실제로 조회될 때(=값이 계산될 때) 그 값을
    `resolved_out[key]` 에도 기록한다(계산된 값의 부산물 기록일 뿐, 판정
    경로에는 영향 없음). 호출자는 evaluate 이후 `_build_facts()` 의
    스냅샷과 이 dict 를 병합해 응답을 구성한다(`run_event`/`run_explain`
    본문 참조) — 조회되지 않은 fact 는 `resolved_out` 에도 나타나지
    않는다(진짜 lazy 를 응답에서도 있는 그대로 반영한다 — "안 물어봤으면
    응답에도 없다").

    ## 자원 정리 — `opened_approval_store`

    `approval.consumption_store` 는 다른 셋과 달리 **자원을 연다**(sqlite
    연결). 값이었을 때는 호출자가 `_build_facts()` 직후 그 반환값을
    쥐고 있다가 함수 종료 시 `close()` 할 수 있었지만, lazy resolver 로
    옮기면 "언제 열릴지"(=조회될지) 호출자가 미리 알 수 없다 — 아예
    한 번도 안 열릴 수도 있다(matched policy 가 없거나 `user_approval`
    을 요구하지 않으면). "열리지 않았으면 닫을 것도 없고, 열렸으면
    반드시 닫혀야 한다"는 경계를 지키기 위해 `opened_approval_store`
    (선택, 기본 `None`) — 호출자가 빈 list 를 넘기면, 이 resolver 가
    실제로 store 를 여는 순간 그 참조를 `opened_approval_store.append(
    store)` 로 되돌려준다. 호출자는 evaluate 이후(성공/실패 무관, try/
    finally) 그 list 가 비어 있지 않을 때만 `close()` 를 호출한다 —
    비어 있으면 애초에 아무 것도 열리지 않았으므로 close 호출 자체가
    없다(`tests/cli/test_build_facts_resource_cleanup.py` 가 이 경계
    양쪽을 모두 고정한다). list 를 쓰는 이유는(단일 변수가 아니라)
    "아직 채워지지 않음"과 "None 값이 채워짐"을 굳이 구분할 필요가
    없어 가장 단순한 컨테이너이기 때문이다 — 이 resolver 는 항상 실제
    store 객체(예외 없이 성공한 경우)만 append 한다(`_open_approval_
    consumption_store()` 가 실패하면 예외가 그대로 전파되고 append 도
    일어나지 않는다 — 열리다 만 상태가 "열림"으로 잘못 기록되지 않는다).

    **cycle 당 1회 계산 보장**: `_git_changeset_facts()` 는 digest/
    sensitive_digest/tag/paths 를 한 번의 호출로 함께 산출하는 단일
    expensive 연산이다. 이를 각각 독립 resolver 로 등록하면서도,
    `EvaluationContext` 의 "fact 키 단위 1회" cache(`_resolve()`)만으로는
    기반 연산까지 묶어주지 않으므로, 지역 closure `_cache` 로 그 기반
    연산 자체를 최대 1회로 묶는다 — 이 cycle 안에서 changeset.digest/
    changeset.task_relevant 등 몇 개를 조회하든 실제 git 연산은 정확히
    한 번만 실행된다.
    """
    if not project_root:
        return None

    from rein.engine.context import (
        FACT_COST_CHEAP,
        FACT_COST_EXPENSIVE,
        FactResolverRegistry,
    )

    cache = {}

    def _compute():
        if "value" not in cache:
            cache["value"] = _git_changeset_facts(project_root)
        return cache["value"]

    def _resolve_digest(context):
        return _compute()[0]

    def _resolve_sensitive_digest(context):
        # digest scope 프로필 분기 (spec §3.6, 함수 docstring "policy_dir"
        # 절) — `strict` 는 STAGED 기준 별도 산정 함수를 직접 호출하고
        # (`_git_changeset_facts()`의 WORKTREE 결과를 재사용하지 않는다),
        # `sensitive`(기본)는 기존과 동일하게 `_compute()` 를 공유한다.
        # `EvaluationContext.fact()` 자체가 fact 키 단위로 이미 1회
        # memoize 하므로(모듈 docstring "cycle 당 1회 계산 보장" 절), 이
        # 분기 자신을 위한 추가 캐시는 두지 않는다 — strict 경로가 여러
        # 번 불릴 일이 없다.
        #
        # `policy_version_cache` 가 채워져 있으면(함수 docstring
        # "policy_version_cache" 절) `_build_facts()` 가 이미 읽어 둔
        # PolicyVersion(또는 None)을 힌트로 `_security_digest_scope_
        # profile()` 에 넘긴다 — **2026-08-20 보강**: 예전에는 그 캐시된
        # 값의 `.digest_scope` 를 여기서 직접 신뢰했지만(재호출 자체를
        # 생략), 그러면 git 추적 컨텍스트에서 s1~s5/m1~m3 판정(spec §3.6
        # "선언의 유효 기준" 절)을 완전히 건너뛰게 된다 — 캐시된 값은
        # `_load_policy_version_fact()` 의 naive worktree 읽기 산물이라
        # git 상태를 모른다. 이제는 항상 `_security_digest_scope_profile()`
        # 을 호출하되, 그 함수가(→ `facts.resolve_policy_version_digest_
        # scope()`) **s5(비 git 문맥)에 한해서만** 이 힌트를 재사용해
        # `_version.yaml` 이중 읽기를 피한다 — git 추적 컨텍스트에서는
        # 힌트를 무시하고 항상 새로 판정한다(그 함수 docstring 참조).
        from rein.kernel.policy import DIGEST_SCOPE_STRICT

        if policy_version_cache:
            digest_scope = _security_digest_scope_profile(
                policy_dir, cached_policy_version=policy_version_cache[0]
            )
        else:
            digest_scope = _security_digest_scope_profile(policy_dir)

        if digest_scope == DIGEST_SCOPE_STRICT:
            from rein.platform.git.facts import strict_security_digest

            return strict_security_digest(cwd=project_root)
        return _compute()[1]

    def _resolve_tag(context):
        return _compute()[2]

    def _resolve_review_digest(context):
        # code_review subject (spec §3.6 "리뷰 digest 범위" 절) — 항상
        # WORKTREE 기준(`_compute()` 의 단일 pass 산출, 위 `_git_changeset_
        # facts()` docstring "review_digest" 항목). security_review 의
        # `_resolve_sensitive_digest` 와 달리 프로필 분기가 없다 — code_
        # review 는 sensitive/strict 이원화 대상이 아니다(spec §3.6, 이
        # 축은 항상 같은 산정 방식 하나뿐).
        return _compute()[4]

    def _record(key, value):
        if resolved_out is not None:
            resolved_out[key] = value
        return value

    def _resolve_task_active(context):
        from rein.platform.task import facts as task_facts

        return _record(
            FACT_TASK_ACTIVE, task_facts.task_active_identifier(project_root)
        )

    def _resolve_task_exists(context):
        # Phase 7 결정 1 — `task_facts.task_exists()` 를 그대로 호출한다
        # (스캔 로직을 여기서 복제하지 않는다, 모듈 docstring "task.exists"
        # fact 항목 참조). `_resolve_task_active` 와 별개 I/O 호출이다 —
        # 두 fact 가 같은 cycle 에서 함께 declared 되는 경우는 배포
        # 기본 세트에 없다(활성 요구 policy 는 별도 requirement 이름
        # `active_task` 를 쓰고, `task.exists` 는 commit/push 조건화
        # 전용) — 중복 스캔 비용은 facts.py 의 "비용 메모" 가 이미
        # cheap 하다고 판단한 것과 같은 근거로 무시한다. `_record` 는
        # `task_facts.task_exists()` 가 낸 `None` 도 그대로
        # `resolved_out[FACT_TASK_EXISTS]` 에 적는다(부재로 바꿔치기
        # 하지 않는다) — 위 `FACT_TASK_EXISTS` 상수 주석 "배선부 문서
        # 정합 수리" 절 참조: 응답에 null 로 나타나도 policy `when:`
        # 매칭 결과는 부재 취급과 동일하다.
        from rein.platform.task import facts as task_facts

        return _record(FACT_TASK_EXISTS, task_facts.task_exists(project_root))

    def _resolve_task_relevant(context):
        from rein.platform.task import facts as task_facts

        if event["tool"] in _TASK_RELEVANT_EDIT_TOOLS:
            relevance_paths = _task_relevance_paths(event, None)
        else:
            relevance_paths = _task_relevance_paths(event, _compute()[3])
        value = None
        if relevance_paths is not None:
            value = task_facts.changeset_task_relevant(relevance_paths)
        return _record(FACT_CHANGESET_TASK_RELEVANT, value)

    def _resolve_action_current(context):
        from rein.platform.claude import facts as claude_facts

        return _record(
            FACT_ACTION_CURRENT, claude_facts.current_action_identifier(event)
        )

    def _resolve_approval_store(context):
        store = _open_approval_consumption_store(project_root, read_only)
        if opened_approval_store is not None:
            opened_approval_store.append(store)
        return _record(FACT_APPROVAL_CONSUMPTION_STORE, store)

    registry = FactResolverRegistry()
    registry.register(FACT_CHANGESET_DIGEST, _resolve_digest, FACT_COST_EXPENSIVE)
    registry.register(
        FACT_CHANGESET_SENSITIVE_DIGEST,
        _resolve_sensitive_digest,
        FACT_COST_EXPENSIVE,
    )
    registry.register(FACT_CHANGESET_TAG, _resolve_tag, FACT_COST_EXPENSIVE)
    registry.register(
        FACT_CHANGESET_REVIEW_DIGEST,
        _resolve_review_digest,
        FACT_COST_EXPENSIVE,
    )
    registry.register(FACT_TASK_ACTIVE, _resolve_task_active, FACT_COST_EXPENSIVE)
    registry.register(FACT_TASK_EXISTS, _resolve_task_exists, FACT_COST_EXPENSIVE)
    registry.register(
        FACT_CHANGESET_TASK_RELEVANT,
        _resolve_task_relevant,
        FACT_COST_EXPENSIVE,
    )
    registry.register(FACT_ACTION_CURRENT, _resolve_action_current, FACT_COST_CHEAP)
    registry.register(
        FACT_APPROVAL_CONSUMPTION_STORE,
        _resolve_approval_store,
        FACT_COST_EXPENSIVE,
    )
    return registry


def _declared_requirements(policies, trigger=None):
    """로드된 `policies` 중 현재 이벤트의 `trigger` 에 맞는 것들이 선언한
    `require:` 이름의 합집합 (Phase 6 마무리 수리 워커 H — hot path 비용
    회귀 수리).

    **Phase 6 3회차 재리뷰 이후 소비처**: 이 함수의 반환값은 더 이상
    changeset 해시(`changeset.digest` 등) 계산 여부를 정하지 않는다 —
    그 게이팅은 `_build_fact_resolvers()` 의 진짜 lazy resolver 로
    대체됐다(위 함수 docstring 참조, "trigger 만 보고 when 은 무시"하는
    이 함수의 근사가 실효 없었던 지점이 바로 거기였다). 이 함수는
    이제 `policy.version` 설정 오류 조기 감지(`_load_policy_version_
    fact` 의 Medium D 안전검사)와 `active_task`/`user_approval` fact
    게이팅에만 쓰인다 — 그 두 용도에는 "trigger 만 보고 when 은 무시"
    하는 이 근사가 여전히 유효하다(설정 오류 조기 감지는 과잉 판정이
    안전한 방향이고, active_task/user_approval 은 기본 policy 세트에
    없어 이 워커가 재현하는 hot-path 문제에 해당하지 않는다).

    **`when` 매칭은 여전히 무시한다** — "이 이벤트에 실제로 matched
    되는가" 가 아니라 "이 이벤트 이름(trigger)에 대응하는 policy 파일들
    안 어딘가에 이 capability 를 요구하는 것이 존재하는가" 만 빠르게
    판정하는 비용 게이팅 힌트다(모듈 docstring "최종 조립" 절). `when`
    조건은 fact 값을 봐야 판정할 수 있는데, 이 함수 자신이 "어떤 fact 를
    계산할지" 를 결정하는 입력이므로 `when` 을 보면 순환 의존이 된다 —
    그래서 `trigger`(정책의 이벤트 이름, `kernel.policy._validate_trigger`
    의 폐쇄 스키마 — 항상 평문 이벤트 식별자)까지만 좁힌다. 좁힌 뒤에도
    같은 trigger 를 공유하는 policy 들 사이에서는 여전히 과다 계산이
    남는다(예: 기본 배포 세트의 commit/push/push-testing/release 4개
    파일 전부가 `trigger: tool.pre` 를 쓰고, 모든 tool 이벤트는 tool
    종류(Bash/Edit/Write/Read)와 무관하게 항상 커널 이벤트 이름
    `tool.pre` 로 정규화되므로(`rein/platform/claude/adapter.py`
    `HOOK_EVENT_NAMES` — native hook 이름 자체는 이 모듈이 참조하지
    않는다, spec §3.1 경계) 이 narrowing 은 그 4개 파일 사이에서는
    아무것도 걸러내지 못한다. `when: command.type: git.commit` 같은
    조건이 실제 구분을 담당하지만 그건 이 함수의 관할이 아니다).

    `trigger=None`(기본값, 하위호환) — 이 인자를 모르는 기존 호출자
    (`_build_facts(event, project_root)` 2-인자 호출, 또는 `event`에
    `"name"` 키가 없는 직접 호출)는 trigger 필터링 없이 이 워커 이전과
    동일하게 전체 합집합을 낸다(과잉 계산 방향의 안전한 fallback —
    "trigger 를 모른다" 는 "아무 policy 도 배제할 수 없다" 로 흡수한다).

    `policies is None`(예: 테스트가 `_build_facts(event, project_root)`
    를 2-인자로 직접 호출하는 기존 경로)이면 빈 집합 — 아무 것도
    선언되지 않은 것과 동일하게 취급해 새 fact 를 계산하지 않는다.
    """
    names = set()
    for loaded in policies or ():
        fields = loaded.get("fields") or {}
        if trigger is not None and fields.get("trigger") != trigger:
            continue
        names.update(fields.get("require") or ())
    return names


def _load_policy_version_fact(policy_dir, declared):
    """`policy_dir` 의 `_version.yaml` 을 읽어 `PolicyVersion` 을 반환하거나 `None`.

    Phase 6 수리 워커 F — 독립 리뷰어 Medium C/D 지적 두 가지를 함께
    고친다(`_EVIDENCE_ISSUED_REQUIREMENTS` 정의 참조):

    - **Medium C**: 이전에는 `os.path.isfile(version_path)` 가 거짓인
      모든 경우 — 파일이 아예 없는 경우 *와* 그 경로에 디렉터리 등 다른
      것이 있는 경우 — 를 똑같이 `None`("미설정")으로 흡수했다. 이제는
      `os.path.exists()` 로 "정말 없음"만 `None` 으로 보내고, 그 경로에
      뭔가 있는데 정규 파일이 아니면(디렉터리 등) `load_policy_version()`
      을 그대로 호출한다 — 그 함수는 `open()` 이 던지는 모든 `OSError`
      (디렉터리라면 `IsADirectoryError`, 그 하위 타입)를 이미
      `PolicyVersionError` 로 변환해 전파하므로(`rein/kernel/policy.py`
      `load_policy_version` 본문), 새 예외 클래스를 만들 필요 없이 그
      기존 fail-closed 경로를 그대로 재사용한다 — "손상"을 "부재"로
      흡수하지 않는다.
    - **Medium D**: 버전 파일이 **진짜로 없을 때**(`os.path.exists()`
      가 거짓), `declared` 가 4종 증거 발급형 capability
      (`_EVIDENCE_ISSUED_REQUIREMENTS`) 중 하나라도 포함하면 조용히
      `None` 을 반환하지 않고 `PolicyVersionError` 로 명시 차단한다 —
      이 네 capability 는 `policy.version` fact 없이는 v2 evaluate() 가
      항상 False 를 내고, ledger 에 evidence 가 하나라도 있으면 그 False
      가 legacy PASS 를 부당하게 뒤집는 landmine 이 된다(모듈 docstring
      "evidence_source 를 의도적으로 배선하지 않는다" 절이 policy.version
      도입 *전*에 이미 경고했던 것과 같은 위험이, policy.version 파일
      부재로 다시 열린다). `declared` 가 이 넷을 하나도 포함하지 않으면
      (activity_task 만 요구하거나 빈 정책 세트) 기존처럼 `None` 을
      반환한다 — 그 경우 이 landmine 자체가 성립하지 않는다(그
      capability 들은 애초에 policy.version 을 쓰지 않는다).

    **리뷰 지적 수리 (2026-08-20, staged 삭제 선차단)** — 위 Medium D
    가드는 원래 "worktree 에 파일이 물리적으로 없다"를 곧바로 "진짜
    미설정"으로 단정했다. 하지만 git 추적 컨텍스트에서 그 부재가 아직
    커밋되지 않은 staged 삭제라면(spec §3.6 s2), 설계 계약은 "커밋
    전까지는 HEAD 의 옛 선언이 여전히 발효"다 — 그런데 이 함수가 그걸
    구분하지 않고 즉시 raise 해, `_evaluate_event()` 전체가 예외로 죽어
    digest_scope 축(`resolve_policy_version_digest_scope()`)이 이미
    올바르게 구현해 둔 s2/m2 판정에 실 CLI 경로에서는 결코 도달하지
    못했다(리뷰어 3케이스 재현). 이제 worktree 부재를 확인한 뒤 바로
    raise 하지 않고, `rein.platform.git.facts.
    resolve_policy_version_for_absent_worktree()` 로 그 부재의 git
    수명주기 의미를 먼저 가른다 — HEAD 에 유효한 선언이 있으면(staged
    삭제, s2) 그 값을 그대로 쓰고, HEAD 가 malformed 인 채 복구
    스테이징 중이면(m2) 이는 "설정 오류"가 아니라 "지금은 판정 불가"라
    조용히 fact 부재로 남긴다(Medium D 랜드마인 가드를 적용하지 않는다
    — 그 가드는 "애초에 설정된 적이 없다"를 노리지 "복구가 진행
    중이다"를 노리지 않는다). 그 밖(HEAD 도 부재 = 진짜 부재/"커밋으로
    부재 발효", non-git)은 기존 그대로 아래 랜드마인 가드로 흘러간다.
    스테이징되지 않은 삭제(index 는 여전히 이전 내용을 가리킴)는
    `PolicyVersionGitStateError` 로 fail-closed 한다(새 헬퍼가 던지고
    이 함수는 그대로 전파 — s3 와 동일한 모호성, 조용히 부재로 흡수하지
    않는다).
    """
    from rein.kernel.policy import (
        PolicyVersionError,
        VERSION_FILENAME,
        load_policy_version,
    )
    from rein.platform.git import facts as git_facts

    version_path = os.path.join(policy_dir, VERSION_FILENAME)
    if not os.path.exists(version_path):
        resolved = git_facts.resolve_policy_version_for_absent_worktree(
            policy_dir
        )
        if resolved is git_facts.POLICY_VERSION_MALFORMED_RECOVERY:
            return None
        if resolved is not None:
            return resolved
        required_by = declared & _EVIDENCE_ISSUED_REQUIREMENTS
        if required_by:
            raise PolicyVersionError(
                "{}: policy version metadata is missing, but the loaded "
                "policy set declares evidence-issued requirement(s) {} — "
                "without policy.version those requirements can never be "
                "satisfied by v2 evidence, and any existing v2 evidence "
                "record silently overrides a valid legacy PASS marker "
                "into BLOCK (Medium D, Phase 6 independent review); this "
                "is a policy configuration error, not an absent "
                "fact".format(version_path, sorted(required_by))
            )
        return None
    return load_policy_version(policy_dir)


def _load_testing_configured_fact(project_root):
    """`.rein/policy/testing.yaml` 존재 여부로 `testing.configured` fact 값을 만든다.

    High A (Phase 6 수리 워커 F, 독립 리뷰어 지적, 부모 판정 타당함) —
    이 헬퍼가 신설되기 전에는 `_build_facts()` 가 이 파일을 전혀 읽지
    않았다: `policies/default/push-testing.yaml` 은 `when: testing.
    configured: "true"` 일 때만 매칭되므로(그 파일 자신의 주석 참조),
    이 fact 가 영원히 부재이면 그 정책은 프로젝트에 `.rein/policy/
    testing.yaml` 이 실제로 존재해도 한 번도 매칭되지 않았다 — 코드
    리뷰 evidence 만 있으면 테스트 없이 `git push` 가 통과했다.

    로더는 Phase 4 Task 4.3 산출물(`rein.capabilities.testing.
    capability.load_testing_config` + `CONFIG_RELATIVE_PATH`)을 그대로
    재사용한다 — 재구현하지 않는다. 이 헬퍼는 `rein/cli/doctor.py` 가
    이미 같은 로더로 같은 파일을 진단 목적으로 읽는 것과 같은 패턴이다
    (계약 문자열 — 상대경로, 파일 부재/손상 의미 — 은 그 한 곳
    `load_testing_config` 에만 있다).

    파일이 없으면(`load_testing_config` 의 '미설정' 계약, `None` 반환)
    이 fact 자체를 만들지 않는다(부재) — `push-testing.yaml` 이 그래야
    매칭되지 않는다(spec §5.2 "미선언 프로젝트 처리" 확정 방향, 온보딩
    마찰 방지). 파일이 있으면 정확히 문자열 `"true"` 를 반환한다 — kernel
    D3 파서가 YAML bool 자동 변환을 하지 않으므로, policy `when:` 비교
    값도 리터럴 문자열이어야 매칭이 성립한다(`push-testing.yaml` 자신의
    "fact 타입 계약" 주석과 동일한 이유). 파일이 있지만 손상됐으면
    (`TestingConfigError`) 그대로 전파한다 — 이 파일의 다른 모든 fact
    계산 헬퍼(`_load_policy_version_fact` 등)와 동일하게 "존재하지만
    손상"을 "부재"로 흡수하지 않는다.
    """
    from rein.capabilities.testing.capability import (
        CONFIG_RELATIVE_PATH,
        load_testing_config,
    )

    path = os.path.join(project_root, CONFIG_RELATIVE_PATH)
    config = load_testing_config(path)
    if config is None:
        return None
    return "true"


def _task_relevance_paths(event, git_changeset_paths):
    """`changeset.task_relevant` 계산에 쓸 경로 tuple, 판정 불가면 `None`.

    모듈 docstring "changeset.task_relevant 의 경로 소스" 절 — Edit/
    Write/MultiEdit 이벤트는 대상 파일 1개(v1 과 동일 비용), git.* Bash
    명령은 이미 계산된 WORKTREE changeset 경로 전체(재계산 없음), 그
    밖은 판정 재료가 없다.
    """
    if event["tool"] in _TASK_RELEVANT_EDIT_TOOLS:
        file_path = (event.get("payload") or {}).get("file_path")
        if isinstance(file_path, str) and file_path:
            return (file_path,)
        return None
    if git_changeset_paths:
        return git_changeset_paths
    return None


def _serializable_facts(facts):
    """응답(JSON)에 실을 `facts` 사본 — 직렬화 불가한 값을 안전하게 치환한다.

    `approval.consumption_store` 의 값은 sqlite 연결을 쥔 객체다
    (`_build_facts()` 참조) — `bin/rein` 이 `decision`/`explanation`
    을 그대로 `json.dump` 하므로(모듈 docstring "최종 조립" 절), 그
    객체를 그대로 노출하면 직렬화 자체가 깨진다. 평가에 실제로 쓰인
    원본 `facts` dict 는 건드리지 않는다(호출자가 그 참조로 store 를
    `close()` 해야 한다) — 이 함수는 항상 얕은 사본을 반환한다.
    """
    sanitized = dict(facts)
    if FACT_APPROVAL_CONSUMPTION_STORE in sanitized:
        sanitized[FACT_APPROVAL_CONSUMPTION_STORE] = True
    return sanitized


def _build_evidence_source(project_root):
    """`project_root` 가 있으면 실 ledger 대조 evidence source, 없으면 `None`.

    `None` 은 `EvaluationContext` 의 기본값(`NullEvidenceSource`)으로
    이어진다 — authority 배선이 이미 project_root 유무로 "적용/미적용"
    을 가르는 것과 같은 경계(모듈 docstring "evidence_source 연결"
    절). 기존 저장소 계층(`platform/sqlite/store.py`,
    `platform/storage/local.py`)을 조합만 한다 — 새 저장 로직 없음.
    """
    if not project_root:
        return None
    from rein.platform.sqlite.store import LedgerVerifiedEvidenceSource
    from rein.platform.storage.local import LocalStateRoot

    return LedgerVerifiedEvidenceSource(LocalStateRoot(project_root))


class _ReadOnlyEmptyApprovalConsumptionStore:
    """`run_explain()` 전용 — 아직 없는 DB 파일을 만들지 않는 무해한 대역.

    Medium E (Phase 6 수리 워커 F, 독립 리뷰어 지적, 부모 판정 타당함) —
    `open_default_approval_consumption_store()`(`rein.platform.storage.
    approval_store`)는 항상 쓰기 가능한 store 를 연다: 디렉토리를
    만들고(`LocalStateRoot.ensure()`), db 파일이 없으면 0600 으로
    새로 만들고(`create_private_file`), 스키마를 보장한다
    (`_ensure_schema` — `CREATE TABLE IF NOT EXISTS`). `run_event()`
    에게는 이게 정상이다 — ALLOW 로 끝나면 실제로 `claim()` 을 호출할
    수 있는 진짜 쓰기 경로가 필요하다. 하지만 `run_explain()` 은 절대
    commit 하지 않는 진단 함수다(`rein/cli/explain.py` 모듈 docstring
    "진단은 상태를 바꾸지 않는다" 절 — 이미 고쳐진 결함). 리뷰어가
    재현한 나머지 결함은: **소비는 안 해도, DB 파일이 아직 없던
    프로젝트에서 explain 을 한 번 부르는 것만으로 그 파일과 스키마가
    새로 생긴다** — 실행 전후로 존재 여부가 바뀐다. "진단은 상태를
    바꾸지 않는다"는 소비 여부만의 계약이 아니라 파일 존재 여부까지
    포함해야 한다.

    이 파일(`rein/cli/__init__.py`)에서 `rein.platform.storage.
    approval_store` 를 수정하지 않고(다른 워커가 동시에 그 파일을
    고치고 있어 편집 금지 — 위임받은 scope 경계) 이 문제를 풀려면,
    DB 파일이 아직 없을 때는 그 모듈을 아예 호출하지 않고 이 대역을
    대신 쓰는 수밖에 없다. 이 대역이 안전한 이유는 **"파일이 아직
    없다"는 사실 자체가 이미 "이 fingerprint 는 아무 것도 소비된 적이
    없다"는 사실과 논리적으로 동치**이기 때문이다 — 갓 만들어진 빈
    테이블에 대한 `is_consumed()` 조회도 항상 `False` 를 낸다. 그래서
    이 대역의 `is_consumed()` 를 항상 `False` 로 고정해도, DB 파일이
    아직 없는 프로젝트에서는 실제 store 를 열어 물어본 것과 **정확히
    같은 답**이 된다 — `run_event()`(실제로 파일을 만드는 진짜 경로)와
    `run_explain()`(이 대역)이 같은 fresh 상태에서 다른 판정을 내리는
    새 결함을 만들지 않는다(`tests/cli/test_explain_state_isolation.py`
    의 parity 테스트가 이를 실측 고정한다 — 직전 라운드에 고친 "explain
    이 다른 판정을 낸다" 결함(Medium 2/4)을 다시 만들지 않기 위한
    핵심 제약).

    `claim()`/`release()` 는 절대 호출되면 안 된다 — `evaluator.
    evaluate()`(`run_explain` 이 부르는 함수, `runtime.evaluate` 가
    아니다)는 예약(`context.reserve_consumption`)만 남길 뿐 commit
    단계 자체가 없는 함수이므로(`explain.py` 모듈 docstring 참조),
    구조적으로 이 두 메서드가 호출될 경로가 없다. 그럼에도 호출되면
    "관대하게 아무 일도 안 하고 성공한 척"하는 대신 즉시 예외로
    실패한다 — 조용한 오판정보다는 시끄러운 버그가 낫다(spec §3.4
    "확인 불가 ≠ 충족" 과 같은 방향의 fail-loud 선택).
    """

    def is_consumed(self, fingerprint):
        return False

    def claim(self, fingerprint):
        raise RuntimeError(
            "read-only diagnostic stand-in approval store was asked to "
            "claim(fingerprint={!r}) — this must never happen: "
            "run_explain() never commits (rein/cli/explain.py module "
            "docstring), so reaching here signals a structural bug, not "
            "a normal code path".format(fingerprint)
        )

    def release(self, fingerprint):
        raise RuntimeError(
            "read-only diagnostic stand-in approval store was asked to "
            "release(fingerprint={!r}) — it never claims anything, so it "
            "should never be asked to release either; this signals a "
            "structural bug".format(fingerprint)
        )

    def close(self):
        # 아무 것도 열지 않았으므로 닫을 것도 없다 — 호출자
        # (run_event/run_explain)는 실제 store 와 이 대역 어느 쪽이든
        # 구분 없이 항상 `.close()` 를 호출한다(duck typing, Low F
        # 정리 경로와 동일한 무조건 호출 계약).
        pass


def _open_approval_consumption_store(project_root, read_only):
    """승인 소비 저장소를 연다 — `read_only=True` 면 새 DB 파일을 만들지도,
    기존 파일의 스키마를 건드리지도 않는다.

    `read_only` 는 `run_explain()` 만 `True` 로 넘긴다(모듈 docstring
    "최종 조립" 절, `_ReadOnlyEmptyApprovalConsumptionStore` 클래스
    docstring 참조). DB 파일이 **이미 존재**하면(과거에 실제
    `run_event()` 가 실제로 만든 파일 — 진짜 소비 이력이 있을 수 있다)
    read_only 여부와 무관하게 항상 실제 소비 이력을 조회한다 — 그래야
    이미 소비된 승인이 "아직 소비 안 됨"으로 잘못 보이는 사고(explain
    이 실제 이력을 무시하고 낙관적으로 판정하는 것)를 피할 수 있다.
    파일이 **아직 없을 때만** `read_only=True` 가 실제 store 생성을
    대역으로 대체한다.

    **Phase 6 3회차 재리뷰 Medium C 시정 — 판정 지점을 `os.lstat` 로
    통일**: 이전에는 "파일이 존재하는가" 를 `os.path.exists()`(심볼릭
    링크를 따라간다)로만 판정했다. 독립 리뷰어가 실증한 두 결함:

    1. **매달린 심볼릭 링크**: 대상이 없으므로 `os.path.exists()` 는
       `False` 를 반환해 explain 은 "파일 없음"으로 보고 무해한 대역을
       쓴다(오류 없이 통과). 반면 실제 `run_event()` 경로(`Approval
       ConsumptionStore.open` → `_reject_symlink_or_special`)는 lstat 로
       링크 자체를 감지해 `OSError` 를 던진다 — explain 은 통과, 실제
       실행은 차단이라는 판정 갈라짐이었다.
    2. **존재하는 빈 정규 파일**: `os.path.exists()` 가 `True` 이므로
       무조건 쓰기 가능한 실제 store(`open_default_approval_consumption_
       store`)를 열었다 — 그 생성자가 스키마를 보장(`CREATE TABLE IF
       NOT EXISTS`)하면서 아직 초기화되지 않은 0바이트 파일이 그 호출
       만으로 ~12288 바이트로 커졌다(진단이 상태를 바꾸는 부작용).

    이제 이 함수가 **먼저** `os.lstat` 로 대상의 실제 종류를 확인하고,
    read_only 여부와 무관하게 심볼릭 링크·특수 파일을 여기서 거부한다
    (`ApprovalConsumptionStore.open` 내부의 `_reject_symlink_or_special`
    과 정확히 같은 판정 — 두 경로가 이제 같은 lstat 결과를 본다). 이미
    존재하는 **정규 파일**을 읽기 전용으로 열 때는 `open_default_
    approval_consumption_store()`(쓰기 가능, 스키마 보장) 대신
    `open_read_only_approval_consumption_store()`(SQLite read-only URI
    연결, 스키마 생성 시도 자체가 없음)를 쓴다 —
    `tests/cli/test_explain_state_isolation.py` 의 두 경계 테스트가
    이 판정을 고정한다.
    """
    import stat as stat_module

    from rein.platform.storage.approval_store import (
        open_default_approval_consumption_store,
        open_read_only_approval_consumption_store,
    )
    from rein.platform.storage.local import LocalStateRoot

    state_root = LocalStateRoot(project_root)
    db_path = state_root.approval_consumption_path()

    # **Phase 6 4회차 독립 리뷰 Medium 2 시정** — 이전에는 `except
    # OSError:` 로 너무 넓게 받아 "파일이 정말 없음"(FileNotFoundError)
    # 과 "lstat 자체가 다른 이유로 실패함"(예: 상위 디렉터리 권한 거부
    # → PermissionError, 경로 구성요소가 디렉터리가 아님 →
    # NotADirectoryError)을 똑같이 "부재"로 흡수했다. 리뷰어 재현: 권한
    # 오류가 나는 상황에서 `run_explain()`(read_only=True)은 이 broad
    # except 를 타고 무해한 빈 대역(`_ReadOnlyEmptyApprovalConsumptionStore`)
    # 으로 "소비되지 않음" 판정을 조용히 내리는데, 실제 실행 경로인
    # `run_event()`(read_only=False)는 같은 권한 오류를 만나 저장소를
    # 열지 못해 실패한다 — 설명과 실행이 반대 판정을 내리는 결함이었다
    # (직전 라운드의 매달린 심볼릭 링크 결함과 같은 클래스: "오류"를
    # "부재"로 흡수하면 안 되는 지점에서 흡수했다).
    #
    # **수리**: `FileNotFoundError`(POSIX ENOENT — 경로 자체가, 또는
    # 그 상위 경로 구성요소가 존재하지 않음)만 "진짜 없음"으로 흡수한다.
    # 그 밖의 `OSError`(권한 거부, 경로 구성요소가 디렉터리가 아님 등)는
    # 판단 재료를 확보하지 못한 상태이지 "부재"가 아니므로 그대로
    # 전파한다 — 두 호출부(`run_event`/`run_explain`) 모두 이 함수를
    # 거치므로, 이 지점에서 판정을 통일하면 설명·실행 갈라짐이 구조적으로
    # 사라진다(`tests/cli/test_open_approval_consumption_store_error_
    # classification.py` 가 이 경계를 고정한다).
    try:
        st = os.lstat(db_path)
    except FileNotFoundError:
        st = None  # 정말로 없음 — 심볼릭 링크조차 아니다.

    if st is not None and not stat_module.S_ISREG(st.st_mode):
        raise OSError(
            "refusing to open approval consumption store at {!r}: not a "
            "regular file (symlink or special file rejected, "
            "fail-closed)".format(db_path)
        )

    if read_only:
        if st is None:
            return _ReadOnlyEmptyApprovalConsumptionStore()
        return open_read_only_approval_consumption_store(state_root)

    return open_default_approval_consumption_store(state_root)


def _build_facts(
    event, project_root, policies=None, policy_dir=None, policy_version_out=None
):
    """이벤트 payload + 프로젝트 상태로부터 실제 fact 를 구성한다.

    `run_event()`/`run_explain()`(`rein/cli/explain.py`) 공유 진입점 —
    모듈 docstring "fact 배선"/"최종 조립" 절 참조. 두 함수가 서로 다른
    fact 계산 경로를 타면 explain 의 "basis 3필드는 run_event 와 항상
    같다" 계약이 다시 깨진다.

    `policies`/`policy_dir` 는 둘 다 선택 인자다(하위호환 — 기존
    `_build_facts(event, project_root)` 2-인자 호출은 새 fact 6종을
    전혀 계산하지 않고 이 워커 이전과 동일하게 동작한다). 프로덕션
    호출부(`run_event`/`run_explain`)는 둘 다 항상 채워 넘긴다.

    **Phase 6 3회차 재리뷰 High 1 + 4회차 독립 리뷰 Medium 1** — 이
    함수는 이제 `changeset.digest`/`changeset.sensitive_digest`/
    `changeset.tag`/`task.active`/`changeset.task_relevant`/
    `action.current`/`approval.consumption_store` 7개를 전혀 계산하지
    않는다(위 "비용 게이팅" 절 + `_build_fact_resolvers()` 모듈 docstring
    "Medium 1" 절 참조) — `_build_fact_resolvers(event, project_root)`
    가 이 7개 전부를 lazy resolver 로 구성해 `runtime.evaluate()`/
    `EvaluationContext` 에 전달해야 한다. 이 함수가 반환하는 `facts`
    dict 에서 이 7개 키는 project_root·policies·이벤트 종류와 무관하게
    항상 부재다 — "계산은 됐지만 값이 없어서 부재"가 아니라 "이 함수는
    애초에 이 7개를 다루지 않는다"는 뜻이다. **Phase 7 결정 1** 이
    `task.exists` 를 같은 lazy 경로에 8번째로 추가했다 — 위 목록과
    동일하게 이 함수는 `task.exists` 도 값으로 계산하지 않는다(부재).
    (`read_only` 인자는 Medium
    1 수리로 이 함수에서 제거됐다 — 승인 소비 저장소를 여는 유일한
    지점이 `_build_fact_resolvers()`/`_open_approval_consumption_store()`
    로 옮겨갔으므로, `run_explain()` 은 이제 그 함수에 직접 `read_only=
    True` 를 넘긴다.)

    `policy_version_out`(선택, 기본 `None`) — `_build_fact_resolvers()`
    의 `_resolve_sensitive_digest` 가 같은 `_version.yaml` 을 다시 읽지
    않도록(`_build_fact_resolvers()` 모듈 docstring "policy_version_
    cache" 절 참조) 이 함수가 이미 로드한 `PolicyVersion` 을 되돌려주는
    부산물 채널이다 — `opened_approval_store`(위 "자원 정리" 절)와 같은
    "값이 아니라 빈 list 를 넘겨받아 append 로 되돌린다" 관례. `policy_
    dir` 가 참일 때만(`_load_policy_version_fact()` 가 실제로 불릴 때만)
    append 되며, 로드 결과가 `None`(버전 파일 진짜 부재)이어도 그대로
    `None` 을 append 한다 — "아직 안 읽음"(list 가 비어 있음)과 "읽었는데
    없음"(list 에 `None` 하나)을 호출자가 구분할 수 있어야 캐시 소비자가
    올바른 기본값(`DIGEST_SCOPE_SENSITIVE`)으로 흡수할 수 있다. `policy_
    dir` 가 거짓이면 이 함수는 애초에 `_load_policy_version_fact()` 를
    부르지 않으므로 append 도 일어나지 않는다(list 는 빈 채로 남아
    소비자 쪽이 기존 fallback 경로를 그대로 탄다). `policy_version_out`
    이 `None`(기본, 하위호환 직접 호출자)이면 이 부산물 기록 자체가
    생략된다 — 판정 경로에는 영향 없다.
    """
    from rein.engine import command_classifier
    from rein.platform import git as git_facts

    facts = {
        FACT_TOOL: event["tool"],
        # project_root 를 cwd 로 넘긴다 — 이전에는 인자 없이 호출해
        # 프로세스의 ambient cwd 에 의존했다. hook 이 자동으로 부르는
        # 경로에서는 그 cwd 가 실제 프로젝트 루트와 다를 수 있다(모듈
        # docstring "authority 배선" 절이 project_root 자체에 대해
        # 이미 명시한 것과 같은 위험 — 여기서는 이미 확보한 project_root
        # 를 다른 git fact 에도 동일하게 적용할 뿐, 새 판단은 아니다).
        # project_root 가 없으면(None) 기존과 동일하게 ambient cwd 로
        # fallback 한다(`current_branch(cwd=None)` 기존 계약).
        FACT_GIT_BRANCH: git_facts.current_branch(cwd=project_root),
    }

    if event["tool"] == "Bash":
        command = (event.get("payload") or {}).get("command")
        if isinstance(command, str) and command:
            facts[FACT_COMMAND_TYPE] = command_classifier.classify(command)

    # `declared` 를 여기서 먼저 계산한다 — 아래 changeset 게이팅
    # (Medium B)과 policy.version 게이팅(Medium D) 양쪽이 이를
    # 참조한다(이전에는 changeset 블록보다 뒤에서 계산됐다).
    #
    # `event.get("name")` 을 trigger 로 넘긴다(Phase 6 마무리 수리 워커
    # H) — 프로덕션 호출부(`run_event`/`run_explain`)는 항상
    # `adapter.normalize_event()` 를 거쳐 `event["name"]` 을 채운다.
    # `event` 에 `"name"` 키가 없는 기존 직접 호출(`_build_facts` 를
    # 테스트가 2/3-인자로 직접 부르는 경로, 예:
    # `tests/cli/test_changeset_fact_dependency_gating.py`)은
    # `event.get("name")` 이 `None` 이 되어 `_declared_requirements` 의
    # 하위호환 fallback(필터링 없음)으로 흡수된다 — 그 기존 테스트들을
    # 건드리지 않는다.
    declared = _declared_requirements(policies, event.get("name"))

    if policy_dir:
        policy_version = _load_policy_version_fact(policy_dir, declared)
        if policy_version_out is not None:
            policy_version_out.append(policy_version)
        if policy_version is not None:
            facts[FACT_POLICY_VERSION] = policy_version.version
            facts[FACT_POLICY_COMPATIBLE_VERSIONS] = (
                policy_version.compatible_versions
            )

    if project_root:
        # High A 수리 — `.rein/policy/testing.yaml` 존재 여부를 실제로
        # 읽는다. 단일 소형 파일 읽기라 policy.version 과 동일하게
        # declared 게이팅 없이 project_root 유무로만 계산한다(비용
        # 무시할 만함, `_load_testing_configured_fact` docstring 참조).
        testing_configured = _load_testing_configured_fact(project_root)
        if testing_configured is not None:
            facts[FACT_TESTING_CONFIGURED] = testing_configured

    # `task.active`/`changeset.task_relevant`/`action.current`/
    # `approval.consumption_store` 는 더 이상 여기서 값으로 계산되지
    # 않는다(Medium 1 수리) — `_build_fact_resolvers()` 가 lazy
    # resolver 로 등록한다(함수 docstring 참조). 이 4개는 예전에
    # `_REQUIREMENT_ACTIVE_TASK`/`_REQUIREMENT_USER_APPROVAL in declared`
    # 로 게이팅됐는데, `declared` 는 trigger 만 보고 `when` 은 무시하는
    # 근사라("실제 matched 되는가" 가 아니라 "이 trigger 의 policy 들
    # 어딘가에 이 requirement 가 선언됐는가") — 리뷰어 재현: `when:
    # command.type: git.commit` 인 `active_task` policy 를 로드해도
    # 파일 편집 이벤트에서 `task_active_identifier()`(I/O) 가 매번
    # 실행됐다. changeset 해시 3종이 이미 겪은 것과 같은 결함이다.

    return facts


def _evaluate_event(event, policy_dir, project_root, db_path):
    """평가 파이프라인 본체 — `run_event()`/`run_hook_event()` 공유 (Task 6.1 선행1).

    `policy_dir`/`project_root`/`db_path` 는 이미 해석이 끝난 값으로
    받는다 — 이 함수 자신은 환경변수를 전혀 읽지 않는다. `run_event()`
    (기존 인자없음 경로 — 환경변수를 그대로 읽어 넘긴다, 미설정 시
    None/None/":memory:")와 `run_hook_event()`(신설 — 미설정 시 자립
    규칙으로 대체한 값을 넘긴다)가 이 세 값을 "어떻게 구했는지"만
    다르고, 그 이후 평가 로직은 완전히 같아야 두 경로가 같은 입력
    조합에서 항상 같은 판정을 낸다는 것이 보장된다 — 그래서 기존
    `run_event()` 본문에서 이 부분만 그대로 떼어냈다(호출부 재배선만,
    로직 변경 없음 — `run_event()` 의 관측 가능한 동작은 이 리팩토링
    전후로 한 글자도 달라지지 않는다: 회귀는
    `tests/unit/test_scaffold_roundtrip.py`/`tests/cli/test_run_event_*`
    가 계속 고정한다). 아래 절별 근거는 이 파일 상단 모듈 docstring
    "registry 배선"/"authority 배선"/"fact 배선"/"최종 조립" 절 참조.
    """
    from rein.engine import runtime
    from rein.platform import sqlite as sqlite_store

    policies = runtime.load_policies(policy_dir)

    # `policy_version_cache` 는 `_build_facts()` 와 `_build_fact_resolvers()`
    # 가 같은 cycle 안에서 공유하는 빈 list 다(`_build_fact_resolvers()`
    # 모듈 docstring "policy_version_cache" 절) — `_build_facts()` 가
    # `policy.version` fact 를 채우려고 이미 읽은 `PolicyVersion`(또는
    # `None`)을 `_resolve_sensitive_digest` 가 재사용해, 같은
    # `_version.yaml` 을 한 cycle 안에서 두 번 읽지 않게 한다. 두 호출
    # 모두에 반드시 같은 참조를 넘겨야 공유가 성립한다 — 각자 새 list 를
    # 만들면 예전과 동일하게 두 번 읽힌다.
    policy_version_cache = []

    facts = _build_facts(
        event,
        project_root,
        policies=policies,
        policy_dir=policy_dir,
        policy_version_out=policy_version_cache,
    )
    # changeset 해시 3종 + task.active/changeset.task_relevant/
    # action.current/approval.consumption_store 7개(+ Phase 7 결정 1 이
    # 추가한 task.exists 로 총 8개)는 이제 `_build_facts()` 가 값으로
    # 계산하지 않는다 — `_build_fact_resolvers()` 가 lazy
    # resolver 로 등록해 `runtime.evaluate()` 에 넘긴다(Phase 6 3회차
    # 재리뷰 High 1 + 4회차 독립 리뷰 Medium 1, `_build_fact_resolvers()`
    # 모듈 docstring 참조).
    #
    # `resolved_out`/`opened_approval_store` 는 이 함수가 만들어 넘기는
    # 빈 컨테이너다 — `_build_fact_resolvers()` 모듈 docstring "응답
    # 투명성"/"자원 정리" 절 참조. evaluate() 가 실제로 어떤 lazy fact 를
    # 조회했는지(`resolved_out`)와 승인 소비 저장소가 실제로 열렸는지
    # (`opened_approval_store`)는 evaluate() 가 끝나기 전까지는 알 수
    # 없으므로, 두 컨테이너를 미리 만들어 resolver 쪽에 주입하고 evaluate
    # 이후 그 내용을 읽는다.
    resolved_out = {}
    opened_approval_store = []
    fact_resolvers = _build_fact_resolvers(
        event,
        project_root,
        policy_dir=policy_dir,
        resolved_out=resolved_out,
        opened_approval_store=opened_approval_store,
        policy_version_cache=policy_version_cache,
    )

    # Low F 수리(Phase 6 독립 리뷰어 지적, 부모 판정 타당함) — 이 지점부터
    # 함수의 나머지 전체(registry/evidence_source 구성, runtime db store
    # 열기, 평가)를 하나의 try/finally 로 감싼다. 그 사이 어느 단계에서
    # 예외가 나도(승인 소비 저장소가 evaluate() 도중 실제로 열렸다면)
    # 반드시 close() 가 실행된다.
    try:
        registry = _build_registry()

        # evidence_source 는 이제 policy.version 이 채워진 뒤에만
        # 안전하게 연결할 수 있다 — `_build_evidence_source()` 가
        # project_root 유무로 "적용/미적용" 을 가른다(모듈 docstring
        # "evidence_source 연결" 절. 과거엔 policy.version 결손 때문에
        # 의도적으로 미배선이었다 — 그 사유가 이제 해소됐다).
        evidence_source = _build_evidence_source(project_root)

        store = sqlite_store.open_store(db_path)
        try:
            decision = runtime.evaluate(
                event["name"],
                facts,
                policies,
                evidence_source=evidence_source,
                registry=registry,
                project_root=project_root,
                fact_resolvers=fact_resolvers,
            )
        finally:
            store.close()
    finally:
        # 승인 소비 저장소는 이제 lazy resolver 가 실제로 조회될 때만
        # (=`opened_approval_store` 가 채워질 때만) 열린다 — 조회되지
        # 않았으면(예: user_approval 을 요구하는 policy 가 매칭되지
        # 않음) 애초에 아무 것도 열리지 않았으므로 닫을 것도 없다
        # (`_build_fact_resolvers()` 모듈 docstring "자원 정리" 절 —
        # "열리지 않았으면 닫을 것도 없고, 열렸으면 반드시 닫혀야 한다"
        # 경계, `tests/cli/test_build_facts_resource_cleanup.py` 고정).
        if opened_approval_store:
            opened_approval_store[0].close()

    # SPIKE-1 왕복이 fact 경로까지 실측 검증할 수 있도록 응답에 동봉 —
    # `resolved_out` 을 `facts` 스냅샷에 병합해야 evaluate() 가 실제로
    # 조회한 lazy fact(예: task.active)까지 응답에 반영된다(`_build_fact_
    # resolvers()` 모듈 docstring "응답 투명성" 절 — 조회 안 된 fact 는
    # 병합 후에도 여전히 부재). 직렬화 불가한 값(approval store 객체)은
    # 사본에서만 치환한다(`_serializable_facts()` 참조).
    merged_facts = dict(facts)
    merged_facts.update(resolved_out)
    decision["facts"] = _serializable_facts(merged_facts)
    return decision


def run_event(raw_text):
    """이벤트 1건을 평가하고 직렬화 가능한 응답 dict 를 반환한다.

    하위호환 계약(모듈 docstring "세 진입 경로" 절) — 절대 손대지
    않는다: 세 환경변수(REIN_POLICY_DIR/REIN_PROJECT_ROOT/REIN_DB_PATH)
    를 그대로 읽어 `_evaluate_event()` 에 넘길 뿐이다. 미설정 시
    policy_dir=None(→ `load_policies(None)` → policy 0개 → ALLOW)/
    project_root=None/db_path=":memory:" — Task 1.1 부터 있던 기존
    기본값 그대로다. 미설정 시 조용히 ALLOW 로 새지 않는 자립 규칙이
    필요한 hook 전용 경로는 `run_hook_event()`(Task 6.1 선행1, 별개
    진입점)를 쓴다 — 이 함수는 그 자립 규칙을 적용하지 않는다.
    """
    # 함수 내 lazy import — 인터프리터 기동 비용 최소화 (spec §3.9)
    from rein.platform import sqlite as sqlite_store
    from rein.platform.claude import adapter

    payload = json.loads(raw_text)
    event = adapter.normalize_event(payload)

    policy_dir = os.environ.get(ENV_POLICY_DIR)
    # 빈 문자열도 "미설정" 취급 — os.environ.get 이 빈 문자열을 그대로
    # 돌려주면 authority 쪽 os.path.join(project_root, ...) 이 조용히
    # cwd-상대 경로로 새는 뒷문이 된다(모듈 docstring "authority 배선"
    # 절 — cwd 로 추정하지 않는다는 계약을 여기서 지킨다).
    project_root = os.environ.get(ENV_PROJECT_ROOT) or None
    db_path = os.environ.get(ENV_DB_PATH, sqlite_store.IN_MEMORY_DB)

    return _evaluate_event(event, policy_dir, project_root, db_path)


# ── hook 전용 자립 진입점 (Task 6.1 선행1) ──────────────────────────
#
# `hooks/hooks.json` 스키마에 `env` 필드가 없어(모듈 docstring 상단
# DoD 배경 참조), 실제 Claude Code hook 실행 경로에서는
# REIN_POLICY_DIR/REIN_PROJECT_ROOT/REIN_DB_PATH 세 환경변수가 하나도
# 채워지지 않는다. `run_event()` 를 그대로 그 경로에 연결하면
# `load_policies(None)` → policy 0개 → 항상 ALLOW 로 새는데, 이는 spec
# §3.4 "판단 불능은 거부 방향" 과 정면으로 어긋난다. 아래 세
# `_resolve_*` 함수가 "명시 환경변수 우선, 없으면 대체값 유도"
# 규칙으로 이 구멍을 막는다 — `run_hook_event()` 가 이 셋을 모아
# `_evaluate_event()` 에 넘긴다.


class ProjectRootResolutionError(RuntimeError):
    """hook 이벤트의 project_root 를 유도할 수 없음 — 판단 불능(BLOCK 대상).

    `REIN_PROJECT_ROOT` 가 미설정이고 payload 에도 쓸만한 `cwd` 가
    없으면(또는 유도 시도가 전부 실패하면) project_root 없이 평가를
    진행하는 대신 이 예외로 명시 실패한다. `ValueError`/
    `json.JSONDecodeError`/`UnknownHookEventError` 가 아닌 일반
    `RuntimeError` 하위이므로, `bin/rein` 의 fail-closed 매핑(순수 입력
    결함 두 예외만 exit 1, 그 밖은 전부 BLOCK + exit 0)에 자연히
    흡수된다 — 별도 분기가 필요 없다(spec §3.4 "판단 불능은 거부
    방향").
    """


# 번들 기본 정책 세트 위치 — `policies/default/`(패키지 부모, 즉
# `plugins/rein-core/` 기준 상대 경로). `bin/rein::_locate_package_parent()`
# 와 동일한 self-location 원칙(자기 파일 경로 기준으로 유도, 값을
# 하드코딩하지 않는다)을 이 파일에서도 독립적으로 구현한다 —
# `bin/rein` 은 확장자 없는 실행 스크립트라 import 로 재사용할 수
# 없다(모듈 단위 함수 공유가 불가능).
_DEFAULT_POLICY_DIR_RELATIVE = ("policies", "default")

# `git rev-parse --show-toplevel` 타임아웃 — `rein.platform.git.facts`
# 의 `_GIT_TIMEOUT_SECONDS` 와 같은 값(5초)을 이 파일에서 독립적으로
# 재선언한다(그 상수는 private, cli 계층에서 import 하지 않는다 — 기존
# 5개 fact 키와 동일한 "로컬 재선언" 관례, 위 `FACT_POLICY_VERSION` 등
# 주석 참조).
_GIT_SHOW_TOPLEVEL_TIMEOUT_SECONDS = 5

# 2회차 리뷰 Medium 수리 — "확인된 저장소 아님" 화이트리스트 판정 기준.
# 실측(scratchpad, macOS git 2.50.1): 비-저장소 디렉토리에서
# `git rev-parse --show-toplevel` 은 항상 종료 코드 **128** + stderr 가
# 정확히 `"fatal: not a git repository"` 로 시작하는 메시지를 낸다(두
# 변형 실측 확인: "...(or any of the parent directories): .git" 과
# "...: '<path>'" — 둘 다 이 접두어를 공유한다). git 소스의 die() 계열
# 호출은 이 문구를 하드코딩하며, 이 환경은 git NLS(.mo 번역 파일) 자체가
# 설치되어 있지 않아(별도 확인) 로케일에 따라 메시지가 달라질 여지가
# 원천적으로 없다 — 그럼에도 NLS 가 설치된 다른 배포 환경(예: 일부
# Linux 배포판)에서는 로케일에 따라 이 메시지가 번역될 수 있으므로,
# `_run_git_show_toplevel()` 은 방어적으로 `LC_ALL=C`/`LANG=C` 를
# 강제해 이 화이트리스트 매칭이 로케일에 흔들리지 않게 고정한다(채택
# 이유 — 이식성 확보, 이 저장소가 지원하는 실행 환경이 이 프로세스
# 하나로 한정되지 않는다는 전제, 비용은 subprocess env dict 복사 1회로
# 무시할 만함).
#
# 화이트리스트 방향 설계(요구사항 2) — "이 경우만 저장소 아님으로
# 인정"이고 나머지는 전부 판단 불능이다. 블랙리스트(예: "dubious
# ownership 문자열만 걸러낸다")로 설계하면 앞으로 나올 새 종류의
# non-zero exit(권한 오류, 손상된 config, 다른 fatal 조건 등)마다
# 매번 새 예외 케이스를 추가해야 하고, 그 사이 기간에는 미지의 실패가
# 전부 "확인된 저장소 아님"으로 오인되어 검증되지 않은 payload cwd 가
# 판정 기준 project_root 로 새어 들어간다 — 이번 수리가 막으려는 것과
# 정확히 같은 모양의 fail-open 이다.
_GIT_NOT_A_REPOSITORY_RETURNCODE = 128
_GIT_NOT_A_REPOSITORY_STDERR_PREFIX = "fatal: not a git repository"


def _is_confirmed_not_a_repository(returncode, stderr_text):
    """`(returncode, stderr_text)` 가 git 의 "확인된 저장소 아님" 화이트리스트에
    매칭되면 `True`, 그 밖의 모든 경우는 `False`(판단 불능 방향).

    두 조건을 **모두** 요구한다 — 종료 코드 128 *그리고* stderr 가
    `"fatal: not a git repository"` 로 시작. 어느 한쪽만으로는 오판정
    여지가 있다: 종료 코드 128 은 git 의 범용 fatal 오류 코드라 "저장소
    아님" 전용이 아니고(예: dubious ownership 도 128 을 쓴다 — git
    문서/소스 기반 추정, 이 리뷰어는 실제 재현에 root 권한이 필요해
    직접 재현하지 못했음을 명시함), stderr 접두어만으로는 우연히 같은
    문자열을 포함하는 무관한 메시지를 걸러내지 못할 수 있다. 두 조건의
    교집합만 화이트리스트에 넣는 것이 "애매하면 차단" 방향(요구사항 3)
    과 일치한다 — 좁게 인정하고 넓게 거부한다.
    """
    if returncode != _GIT_NOT_A_REPOSITORY_RETURNCODE:
        return False
    return stderr_text.strip().startswith(_GIT_NOT_A_REPOSITORY_STDERR_PREFIX)


def _package_root():
    """이 파일 위치 기준으로 패키지 부모 디렉토리(`plugins/rein-core`)를 유도한다.

    `rein/cli/__init__.py` → `rein/cli` → `rein` → `plugins/rein-core`
    (3단계 dirname). `CLAUDE_PLUGIN_ROOT` 환경변수에 의존하지 않는다 —
    hook 실행 환경에서 그 변수가 보장되지 않는다(DoD 명시 요구사항).
    """
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )


def _default_policy_dir():
    return os.path.join(_package_root(), *_DEFAULT_POLICY_DIR_RELATIVE)


def _resolve_policy_dir():
    """`REIN_POLICY_DIR` 이 있으면 그대로, 없으면 번들 기본 정책 디렉토리.

    명시 환경변수가 항상 우선한다 — 자립은 어디까지나 미설정 시 대체
    (DoD "자립 규칙" 절). 반환된 경로가 실제로 로드 가능한지는 이
    함수의 관심사가 아니다 — `runtime.load_policies()` 가 로드 시점에
    검증하고 실패하면 `PolicyLoadError` 를 던진다(그 예외는 호출자의
    fail-closed 매핑을 그대로 탄다 — 여기서 존재를 미리 검사해 선제
    차단할 필요가 없다, `_evaluate_event()`/`run_event()` 가 이미 같은
    방식으로 정책 로드 실패를 다룬다).
    """
    explicit = os.environ.get(ENV_POLICY_DIR)
    if explicit:
        return explicit
    return _default_policy_dir()


class _GitInvocationError(RuntimeError):
    """`git rev-parse --show-toplevel` 이 "판단 자체가 불가"한 두 경우를 함께 나타낸다.

    Task 6.1 선행1 코드 리뷰 Medium 2 수리 — "git 이 정상 실행되어
    저장소가 아니라고 답한 경우"(non-zero exit, 예: `fatal: not a git
    repository`)와 "실행 자체가 실패한 경우"(git 바이너리 부재/PATH
    문제 → `OSError`, timeout → `subprocess.TimeoutExpired`)는 서로
    다른 사건이다 — 전자는 "판단 결과가 아니오", 후자는 "판단 자체가
    불가"다. 수리 전에는 `_run_git_show_toplevel()` 이 둘 다 `None` 으로
    뭉갰고, `_resolve_project_root()` 는 그 `None` 을 "확실히 저장소
    아님"과 동일하게 취급해 payload 의 `cwd` 로 조용히 폴백했다(리뷰어
    실측 재현: git 실행 불능 상태에서도 차단되지 않고 하위 디렉토리가
    그대로 project_root 로 쓰였다).

    **2회차 리뷰 Medium 수리 — 세 번째 경우를 추가로 이 예외에 흡수한다**:
    "git 이 정상 실행됐고 종료 코드도 non-zero 이지만, 그 실패가 화이트
    리스트(`_is_confirmed_not_a_repository`)가 인정하는 '확인된 저장소
    아님' 신호와 일치하지 않는 경우"(대표 사례 — git 2.35.2+ 의 "dubious
    ownership" 안전장치, CVE-2022-24765 대응: 컨테이너/CI 에서 저장소가
    다른 uid 로 마운트되면 정상 실행 + non-zero exit 이면서도 "저장소가
    아니다"가 아니라 "소유자 불일치로 판정을 거부한다"는 뜻이다). 이전
    수리(1회차)는 실행 계층(`OSError`/timeout)만 이 예외로 분리했고,
    결과 계층(비어있지 않은 정상 실행 + 화이트리스트 밖 non-zero exit)은
    여전히 "확인된 저장소 아님"과 뭉뚱그려 `None` 폴백을 탔다 — 이번
    수리가 막는 것이 바로 그 좁은 범위의 잔존 fail-open 이다. 세 경우
    모두 호출자 입장에서는 "git 에게 명확한 저장소 아님 답을 받지
    못했다"는 동일한 결론으로 이어지므로 같은 예외 타입으로 묶는다 —
    `_resolve_project_root()` 는 이 예외 하나만 잡으면 세 경우 전부를
    `ProjectRootResolutionError`(판단 불능 → 거부 방향, spec §3.4)로
    승격할 수 있다. `ValueError`/`json.JSONDecodeError`/
    `UnknownHookEventError` 가 아닌 일반 `RuntimeError` 하위이므로,
    (이 예외를 명시적으로 잡아 변환하지 않았다면) `bin/rein` 의
    fail-closed 매핑에도 자연히 흡수됐을 것이다 — 그럼에도 명시
    변환하는 이유는 `ProjectRootResolutionError` 하나로 "project_root
    유도 실패"의 원인을 통일해 호출자·테스트가 단일 예외 타입만
    신경 쓰면 되게 하기 위해서다.
    """


def _run_git_show_toplevel(cwd):
    """`git rev-parse --show-toplevel` 실행 결과를 3가지로 분류한다.

    - **성공**(정상 실행 + exit 0): stdout 을 strip 한 값이 비어있지
      않으면 그 절대경로 문자열. **exit 0 인데 stdout 이 빈 문자열인
      경우도 이 분기를 통과해 `None` 을 반환한다** — 즉 호출자
      (`_resolve_project_root()`) 에서는 이 경우도 "확인된 저장소 아님"
      과 같은 `None` 폴백 신호로 관측된다(2회차 리뷰 Low 지적 — 이전
      docstring 은 이 경우를 명시하지 않아 문서-구현 불일치였다). 실제
      git 은 정상 저장소에서 `--show-toplevel` 에 빈 stdout 을 내는
      경우가 알려져 있지 않으므로 이 분기가 실전에서 관측되는 사례는
      아니지만, 코드 경로 자체는 존재하므로 정확히 기술한다 — 이 분기의
      동작을 바꾸는 것은 이번 수리의 범위 밖이다(요구사항 5는 문서를
      실제 동작에 맞추라는 것이지 동작을 바꾸라는 것이 아니다).
    - **확인된 저장소 아님**(정상 실행 + non-zero exit **이고**
      `_is_confirmed_not_a_repository()` 화이트리스트에 매칭): `None` —
      git 스스로 명확히 "저장소가 아니다"라고 답한 경우이므로, 호출자가
      payload cwd 로 폴백해도 안전하다(기존 관례 유지).
    - **판단 불능**(`_GitInvocationError`, 두 경우를 함께 포함 — 클래스
      docstring 참조):
      1. subprocess 자체가 실패 — `OSError`/`subprocess.TimeoutExpired`.
      2. 정상 실행 + non-zero exit **이지만** 화이트리스트에 매칭되지
         않음(예: git 2.35.2+ 의 "dubious ownership" 거부, 그 밖의 알 수
         없는 fatal 조건) — "저장소 아님"이 아니라 "git 이 판정 자체를
         거부했다"는 뜻이므로, 확인되지 않은 채로 `None`(=저장소 아님)
         과 뭉개지 않는다(요구사항 1/3 — 애매하면 차단 방향).

    로케일 고정 — `LC_ALL=C`/`LANG=C` 를 강제한 환경으로 실행한다(위
    `_GIT_NOT_A_REPOSITORY_STDERR_PREFIX` 주석 "채택 이유" 참조). 이
    저장소의 개발/실행 환경(macOS git 2.50.1, NLS 미설치)에서는 이미
    로케일 무관하게 영문 메시지만 나오는 것을 실측했지만, git NLS 가
    설치된 다른 배포 환경까지 이 화이트리스트 매칭이 흔들리지 않게
    방어적으로 고정한다.

    `rein.platform.git.facts._run_git()` 과 같은 subprocess 관례
    (timeout + capture_output + check=False)를 따른다 — 그 함수는
    모듈 private 이라 이 파일에서 import 하지 않고 같은 패턴만
    독립적으로 반복한다(모듈 경계를 넘는 private 함수 참조를 피한다).
    """
    import subprocess

    env = dict(os.environ)
    env["LC_ALL"] = "C"
    env["LANG"] = "C"

    try:
        proc = subprocess.run(
            ("git", "rev-parse", "--show-toplevel"),
            cwd=cwd,
            capture_output=True,
            timeout=_GIT_SHOW_TOPLEVEL_TIMEOUT_SECONDS,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise _GitInvocationError(
            "git rev-parse --show-toplevel could not be executed for cwd "
            "{!r}: {}: {}".format(cwd, type(error).__name__, error)
        ) from error
    if proc.returncode != 0:
        stderr_text = proc.stderr.decode("utf-8", errors="replace")
        if _is_confirmed_not_a_repository(proc.returncode, stderr_text):
            return None
        raise _GitInvocationError(
            "git rev-parse --show-toplevel exited with status {} for cwd "
            "{!r}, but this does not match the whitelisted 'confirmed not "
            "a git repository' signature (exit {} + stderr starting with "
            "{!r}) — treating this as indeterminate rather than a "
            "confirmed non-repository answer (e.g. git's 'dubious "
            "ownership' safeguard also exits non-zero without meaning "
            "'not a repository'); stderr was: {!r}".format(
                proc.returncode,
                cwd,
                _GIT_NOT_A_REPOSITORY_RETURNCODE,
                _GIT_NOT_A_REPOSITORY_STDERR_PREFIX,
                stderr_text.strip(),
            )
        )
    candidate = proc.stdout.decode("utf-8", errors="replace").strip()
    return candidate or None


def _resolve_project_root(payload):
    """`REIN_PROJECT_ROOT` 이 있으면 그대로, 없으면 payload 의 `cwd` 에서 유도한다.

    `hooks/lib/project-dir.sh::resolve_project_dir()` 의
    `CLAUDE_PLUGIN_ROOT` 분기(git rev-parse --show-toplevel from cwd,
    실패 시 그 디렉토리 자체로 폴백)와 같은 순서를 따른다 — 다만 그
    셸 함수는 최종 폴백으로 ambient `$PWD` 를 써서 항상 성공하지만,
    이 함수는 ambient 프로세스 cwd 를 신뢰하지 않는다(모듈 docstring
    "authority 배선" 절 — hook 자동 판정 경로에서는 cwd 로 추정하지
    않는다는 기존 결정과 같은 이유). 그래서 출발점(`payload["cwd"]`)
    자체가 없거나 못 쓰면 `ProjectRootResolutionError` 로 명시 실패한다
    — "판단 불능은 거부 방향"(spec §3.4)이 project_root 유도 실패에도
    동일하게 적용된다.

    git 판단 불능(1회차 리뷰 Medium 2 + 2회차 리뷰 Medium 수리):
    `_run_git_show_toplevel()` 이 `_GitInvocationError` 를 던지면(git
    바이너리 부재·timeout 등 "실행 자체가 불가", **또는** git 은 정상
    실행됐지만 non-zero exit 이 "확인된 저장소 아님" 화이트리스트
    (`_is_confirmed_not_a_repository()`)에 매칭되지 않는 경우 — 대표
    사례가 git 2.35.2+ 의 "dubious ownership" 거부다) 여기서도
    `ProjectRootResolutionError` 로 승격한다 — payload cwd 로 조용히
    폴백하지 않는다. "git 이 정상 실행되어 저장소가 **확실히** 아니라고
    화이트리스트 기준으로 답한 경우"(`None` 반환)만 기존대로 cwd 폴백을
    허용한다 — 그 밖의 모든 non-zero exit(뭉뚱그려 흡수하면 손상된
    PATH·리소스 고갈로 인한 timeout·소유자 불일치 거부 등 서로 다른
    사건이 전부 "저장소 아님"으로 오판정된다)는 검증되지 않은 cwd 가
    판정 기준 project_root 로 그대로 쓰이는 구멍을 막기 위해 판단
    불능으로 분류한다(`_GitInvocationError` 클래스 docstring 참조).

    symlink/realpath 정책(코드 리뷰 Medium 2 "명시적으로 고정" 요청):
    이 함수는 `os.path.realpath()` 로 반환값을 정규화하지 **않는다** —
    git toplevel 분기는 git 자신의 `--show-toplevel` 해석 결과를, 비-git
    폴백 분기는 payload 의 `cwd` 값을 그대로 신뢰한다. 두 값이 심볼릭
    링크를 경유해도, 이후 이 project_root 밑에서 실제로 열리는 모든
    파일(`LocalStateRoot` 산하 ledger/evidence/db 등)은 OS 파일 열기
    계층에서 어차피 같은 실제 파일을 가리키므로(심볼릭 링크는 어느
    표기로 접근해도 동일 대상으로 귀결), 이 함수 수준에서 문자열을
    realpath 로 바꾸는 것은 추가 보안 이득이 없다 — 오히려 기존
    회귀 테스트(`tests/cli/test_run_hook_event_self_reliance.py::
    ResolveProjectRootTest::test_non_git_directory_falls_back_to_cwd_itself`)
    가 고정한 "payload cwd 를 그대로 반환한다"는 계약을 깨뜨린다(macOS
    등 tempdir 자체가 symlink 인 환경에서 값이 달라짐). 이 함수가 실제로
    다루는 위험은 경로 표기의 정규화가 아니라 "판단 불능을 거부
    방향으로 보내는가"(위 절)이고, state 디렉토리 자체에 미리 심어진
    심볼릭 링크에 대한 방어는 관심사가 다른 별도 지점
    (`LocalStateRoot.ensure()`)이 담당한다.
    """
    explicit = os.environ.get(ENV_PROJECT_ROOT)
    if explicit:
        return explicit
    payload_cwd = payload.get("cwd") if isinstance(payload, dict) else None
    if not isinstance(payload_cwd, str) or not payload_cwd:
        raise ProjectRootResolutionError(
            "cannot derive project root: REIN_PROJECT_ROOT is unset and "
            "the hook payload has no usable 'cwd' field"
        )
    try:
        toplevel = _run_git_show_toplevel(payload_cwd)
    except _GitInvocationError as error:
        raise ProjectRootResolutionError(
            "cannot derive project root: git rev-parse --show-toplevel "
            "could not be executed for cwd {!r} ({}) — refusing to fall "
            "back to an unverified cwd (execution failure is not the "
            "same as a confirmed 'not a repository' answer)".format(
                payload_cwd, error
            )
        ) from error
    if toplevel and os.path.isdir(toplevel):
        return toplevel
    if os.path.isdir(payload_cwd):
        return payload_cwd
    raise ProjectRootResolutionError(
        "cannot derive project root: payload cwd {!r} is not a directory "
        "and git rev-parse --show-toplevel failed".format(payload_cwd)
    )


def _resolve_db_path(project_root):
    """`REIN_DB_PATH` 가 있으면 그대로, 없으면 프로젝트 루트 하위 기본 경로.

    기존 저장소 규약(`rein.platform.storage.local.LocalStateRoot.
    database_path()` — `doctor`/여러 테스트가 이미 쓰는 경로)을 그대로
    재사용한다 — 새 경로를 신설하지 않는다. 인자 없는 기존
    `run_event()` 경로는 이 함수를 타지 않고 여전히 `:memory:` 기본값을
    쓴다(그 경로의 계약은 손대지 않는다). 디렉토리가 아직 없으면
    만든다(`LocalStateRoot.ensure()`, `open_default_approval_
    consumption_store()` 와 동일 관례) — `sqlite3.connect()` 는 부모
    디렉토리를 스스로 만들지 않으므로, 만들지 않으면 첫 hook 호출마다
    `OperationalError` 로 실패해(결과적으로 fail-closed BLOCK 이긴
    하지만) 정상 판정 자체가 영원히 불가능해진다.

    ## db 파일 하드닝 (Task 6.1 선행1 코드 리뷰 Medium 3/4 수리)

    `_evaluate_event()`(`run_event()`/`run_hook_event()` 공유 평가
    본체, `run_event` 무손상 제약으로 이 함수 자체는 수정하지 않는다)
    가 실제로 db 를 여는 지점(`rein.platform.sqlite.open_store()` —
    `sqlite3.connect()` 를 그대로 감싼 저수준 진입점)은 `rein.platform.
    sqlite.store.SqliteStore.open()`/`rein.platform.storage.
    approval_store.ApprovalConsumptionStore.open()` 이 이미 적용한
    하드닝(신규 파일 0600 선생성 + 심볼릭 링크 거부)을 거치지 않는다
    — 그 결과 신규 기본 db 파일이 umask 영향을 받는 기본 권한(0644)
    으로 생성되고, db 경로에 미리 심어진 심볼릭 링크를 그대로 따라가는
    두 결함이 리뷰어 실측으로 재현됐다(spec §3.8 은 신규 runtime 파일
    0600 을 요구).

    이 함수(`run_hook_event()` 전용 경로 — `run_event()`/`doctor`/
    `explain` 은 이 함수를 타지 않으므로 그 세 경로의 동작은 이 수리로
    한 글자도 바뀌지 않는다)가 db 경로를 반환하기 **전에** 같은 두
    하드닝을 선제 적용한다 — `create_private_file()` 로 파일이 아직
    없으면 0600 으로 먼저 만들어 두면(이미 존재하는 파일은 건드리지
    않는다), 뒤이어 `_evaluate_event()` 가 여는 `sqlite3.connect()` 는
    "이미 있는 0600 파일을 여는" 것이 되어 새 파일을 만들지 않는다
    (`SqliteStore.open()` 의 "파일을 sqlite 보다 먼저 0600 으로 만들어
    두면 WAL/SHM sidecar 도 같은 권한을 상속한다" 관례와 동일). 그 다음
    `reject_symlink_or_special_file()` 로 lstat 기반 심볼릭 링크 거부를
    적용한다 — `create_private_file()` 의 O_CREAT|O_EXCL 는 대상이
    이미 심볼릭 링크면 EEXIST 로 조용히 실패하고 지나갈 뿐 막지 않으므로
    (링크를 따라가지 않을 뿐), 명시적으로 거부하는 이 두 번째 단계가
    없으면 뒤이은 `sqlite3.connect()` 가 그 링크를 그대로 따라가 db 를
    프로젝트 밖에 쓴다. 이 저장소가 이미 3지점에서 확립한 것과 동일한
    패턴(`local.py` 모듈 docstring/`reject_symlink_or_special_file`
    참조) — 새 방식을 발명하지 않는다. 명시 `REIN_DB_PATH` 오버라이드
    (위 조기 반환)에는 적용하지 않는다 — 그 경로는 운영자가 명시
    지정한 값이고, 이 수리가 재현하는 문제(자동 유도된 기본 경로의
    하드닝 누락)의 대상이 아니다.
    """
    explicit = os.environ.get(ENV_DB_PATH)
    if explicit:
        return explicit
    from rein.platform.storage.local import (
        LocalStateRoot,
        create_private_file,
        reject_symlink_or_special_file,
    )

    state_root = LocalStateRoot(project_root)
    state_root.ensure()
    db_path = state_root.database_path()
    create_private_file(db_path)
    reject_symlink_or_special_file(db_path)
    return db_path


def run_hook_event(payload):
    """Task 6.1 선행1 — 자립 규칙을 적용하는 hook 전용 평가 진입점.

    `run_event()`(raw text 를 받는 기존 계약)와 달리 이미 파싱된
    `payload` dict 를 받는다 — 호출자(`bin/rein` 의 `hook` 서브커맨드)
    가 native 응답 변환에 쓸 `hook_event_name` 을 이 함수 호출 전에
    이미 알아야 하므로, JSON 파싱을 호출자와 중복하지 않기 위함이다.

    REIN_POLICY_DIR/REIN_PROJECT_ROOT/REIN_DB_PATH 세 환경변수가 전부
    미설정이어도 `_resolve_policy_dir()`/`_resolve_project_root()`/
    `_resolve_db_path()` 가 번들 기본 정책·payload cwd 유도·프로젝트
    루트 하위 기본 db 경로로 대체한다 — `run_event()` 처럼 정책 0개로
    새어 무조건 ALLOW 로 흐르지 않는다. 명시 환경변수는 항상 우선한다.
    유도 자체가 불가능하면(project_root) `ProjectRootResolutionError`
    를, 정책 디렉토리가 없거나 손상됐으면(`load_policies()` 내부)
    `PolicyLoadError` 를 던진다 — 둘 다 이 함수가 삼키지 않고 그대로
    전파한다(호출자의 fail-closed 매핑이 BLOCK 으로 흡수한다).

    반환값은 `run_event()` 와 동일한 raw kernel decision dict(대문자
    ALLOW/BLOCK/ASK_USER, `Decision.to_dict()` 5필드 계약) — native
    Claude 응답 변환은 이 함수의 책임이 아니다(`adapter.
    to_native_response()`, 호출자 소관).
    """
    from rein.platform.claude import adapter

    event = adapter.normalize_event(payload)

    policy_dir = _resolve_policy_dir()
    project_root = _resolve_project_root(payload)
    db_path = _resolve_db_path(project_root)

    return _evaluate_event(event, policy_dir, project_root, db_path)
