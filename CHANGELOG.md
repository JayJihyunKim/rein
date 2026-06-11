# Changelog

> **Versioning policy**: 버전 bump 는 `.claude/rules/versioning.md` 의 Rule A/B/C 를 따른다.

## v1.5.1 — 2026-06-11 (페르소나가 발동 안 되던 문제 수정)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **v1.5.0 에서 켜진 페르소나가 실제로는 발동하지 않던 문제를 수정합니다.** 세션 시작 시 주입되던 규칙 + 페르소나가 한 덩어리로 너무 커져서 잘려나가, 페르소나뿐 아니라 일부 운영 규칙 본문까지 어시스턴트에 도달하지 못했습니다. 이제 세션 시작에는 각 규칙의 짧은 요약을 주입하고(전체 본문은 필요 시 읽습니다), 페르소나는 별도로 분리해 항상 도달하도록 했습니다. 페르소나는 매 턴 가볍게 유지되어 긴 세션에서도 흐려지지 않습니다 — 말투에만 적용되고 판단·경고·차단은 냉정하게 유지되는 원칙은 그대로입니다.

> 버전 등급 메모: 세션시작 hook 의 주입 오작동(과대 출력 truncation) 수정 → patch(1.5.1) (versioning Rule A, "hook 오작동 수정"). 매턴 페르소나 유지는 도달 신뢰성 장치로 수정에 포함.

## v1.5.0 — 2026-06-09 (페르소나 프리셋 + 코드 리뷰 게이트 무결성 수정)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **어시스턴트에 교체 가능한 페르소나가 추가되고 기본으로 켜집니다 (`boss-ace`).** 기본 프리셋은 사용자를 "보스"라 부르는 과잉충성 "조직의 에이스" 말투입니다 — 단 **말투에만** 적용되고 판단·경고·차단 같은 운영 정보는 냉정하게 유지됩니다 (응답 규칙이 항상 우선). 끄려면 `.rein/policy/persona.yaml` 에 `enabled: false` 한 줄이면 됩니다. 한국어는 정극 충성 톤, 영어는 self-aware 윙크 톤으로 갈리며, 프리셋은 향후 교체·확장할 수 있습니다.
- **codex 코드 리뷰 게이트의 무결성 결함 여러 건이 수정됩니다.** (1) codex 호출이 실패해도 성공(통과)으로 처리되던 fail-open, (2) 리뷰 본문에 인용된 예시 판정을 실제 결론으로 오인하던 파서, (3) 미커밋(작업 중) 변경 대신 무관한 이전 커밋을 리뷰하던 문제, (4) 비교 기준·라벨이 리뷰 대상과 어긋나던 문제. 모두 리뷰가 "통과시키면 안 될 것을 통과"시키거나 "엉뚱한 대상을 리뷰"하던 종류라 리뷰 신뢰성이 올라갑니다.

> 버전 등급 메모: 새 user-exposed 기능(페르소나 프리셋) 추가 → minor(1.5.0) (versioning Rule A). 같은 날 v1.4.7 이후 추가 배포는 게이트 무결성 핫픽스 명분 + 사용자 결정으로 Rule B(같은 날 1버전) override.

## v1.4.7 — 2026-06-09 (codex 리뷰 모델 단일화)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **codex 코드 리뷰와 문서(설계서·플랜) 리뷰가 같은 모델(`gpt-5.5`)로 통일됩니다.** v1.4.6 에서 모델명을 한 파일로 모으며 역할을 코드 리뷰용·분석용으로 나눴는데, 이번에는 코드 리뷰와 문서 리뷰를 구분 없이 `gpt-5.5` 하나로 맞췄습니다. 역할별 변수(`CODE_MODEL`/`ANALYSIS_MODEL`)는 나중에 다시 코드 특화 모델로 분리할 수 있도록 그대로 두되 값만 같게 했습니다. 코드 리뷰 시 강도(깊이) 선택 등 다른 동작은 그대로이며, 바뀌는 것은 리뷰가 실제로 호출하는 모델 이름뿐입니다.

> 버전 등급 메모: 사용자 codex 리뷰가 호출하는 모델명 변경 + 새 명령/스킬 표면 추가 없음 → patch(1.4.7) (versioning Rule A).

## v1.4.6 — 2026-06-08 (codex 모델 관리 단일화 + 모델 변경 안전장치)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **codex 모델명이 한 곳에서 관리되고, codex 가 모델 이름을 바꿔도 조용히 실패하지 않습니다.** 이전에는 codex 리뷰·질문 스킬 여러 곳에 모델명이 하드코딩돼 있어, codex 가 모델을 rename 하면(예: `gpt-5.3-codex` → `gpt-5.3-codex-spark`) 죽은 이름이 남아 리뷰가 조용히 로드 실패했습니다. 이제 모델명은 `plugins/rein-core/config/codex-models.sh` 한 파일에서만 관리되고(코드 리뷰용·분석용 역할별 분리), 모델 로드가 실패하면 "모델명이 바뀐 것 같다 — 이 파일의 이 항목을 고치세요"를 경로·변수명과 함께 안내합니다. 잘못된 모델로 리뷰가 통과 처리되는 일도 막습니다.

> 버전 등급 메모: 죽은 모델명 로드 실패 수정 + 견고성 개선이며 새 명령/스킬 표면 추가가 없어 patch(1.4.6) (versioning Rule A).

## v1.4.5 — 2026-06-05 (신규 설치 첫 세션 안내 + 세션 상태의 git 기록 자동화)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **새 저장소 첫 세션에 짧은 온보딩 안내가 한 번 표시됩니다.** rein 을 갓 설치한 저장소의 첫 세션에서, "코드가 들어오기 전에 무엇을 할지 정하기 → 사용자 승인 → 리뷰 통과" 흐름을 1회만 안내합니다(이후 세션엔 표시 안 됨). 또 핵심 게이트(작업 정의 전 소스 편집·커밋 전 리뷰 등)에 막혔을 때 차단 메시지가 "막힌 이유"뿐 아니라 **"곧 필요할 다음 단계"**까지 알려줘, 막혔다 푸는 왕복이 줄어듭니다. 작업 정의 문서의 승인 줄을 불릿/볼드가 아니라 평문 한 줄로 쓰라는 형식 힌트도 차단 메시지에 포함됩니다.

- **세션 상태의 git 사실(브랜치·커밋/푸시 여부·변경 수·최신 태그)이 자동으로 기록·표시됩니다.** 이전에는 상태 메모(`trail/index.md`)에 git 현황을 사람이 손으로 적어 실제와 어긋나곤 했습니다(예: 이미 푸시했는데 "미푸시"로 남음). 이제 세션 시작·종료마다 훅이 git 에서 직접 사실을 읽어 자동 블록으로 보여주고(`.rein/state/git-snapshot.md`, 커밋되지 않는 임시 파일), 상태 메모 본문에는 git 수치를 손으로 쓰지 않도록 안내합니다. 손으로 쓴 git 수치가 남아 있으면 세션 종료 시 가벼운 안내가 표시됩니다(차단 아님). git 명령은 로컬만 사용하며 네트워크 조회는 하지 않습니다.

- **스마트 라우팅 정의 문서의 빈틈·불일치가 정리됐습니다.** 라우팅 맵과 라우팅 절차의 두 조합표가 어긋나던 것을 한쪽을 다른 쪽의 요약본으로 명시해 정합시키고, 실제로 하지 않는 동작(미반영 학습 루프·디스크 스캔 등)을 문서·스크립트에서 정직하게 제거했습니다. 동작 변화보다는 정의의 정확도 개선입니다.

> 버전 등급 메모: 새 사용자 표면(첫 세션 온보딩 안내 + 세션 git 스냅샷 블록) 기준 권고는 minor 이나, 메인테이너 판단으로 patch(1.4.5) 로 릴리스 (versioning Rule A 는 advisory).

## v1.4.4 — 2026-06-04 (설계 문서를 전용 에이전트 없이 직접 쓰면 안내)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **스펙/계획 문서를 전용 작성 에이전트 없이 직접 쓰면 부드러운 안내가 표시됩니다(차단 아님).** `docs/specs/` · `docs/plans/` 아래 문서가 `spec-writer`/`plan-writer` 를 거치지 않고 인라인으로 작성되면, 편집 직후 도는 훅이 "전용 작성 경로로 다시 작성하는 편이 안전합니다 — 의도한 수동 작성이면 이 안내는 무시해도 됩니다" 안내를 띄웁니다. 정상 경로(전용 에이전트가 작성)에서는 안내가 뜨지 않습니다. **차단이 아니므로** 수동 수정·리뷰 보정·외부 에디터 작성·마이그레이션은 그대로 동작합니다. 설계 문서를 쓸 때만 발동하므로 매 편집/명령마다 도는 일반 훅 속도에는 영향이 없습니다.

> 버전 등급 메모: 새 훅 안내 동작 기준 권고는 minor 이나, advisory·비차단·대상이 좁아(설계 문서 작성 시에만) 메인테이너 판단으로 patch(1.4.4) 로 릴리스 (versioning Rule A 는 advisory).

## v1.4.3 — 2026-06-02 (스펙 작성 에이전트 + 계획 작성 경로 통일 + 훅 속도·견고화)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **스펙 작성 전용 에이전트가 추가됩니다.** 브레인스토밍 산출물(`docs/brainstorms/` 문서)을 읽어 rein 규격의 스펙(`docs/specs/`)을 작성하고, 작성 직후 자동으로 독립 검토를 거쳐 통과 시 검토 표시를 남기는 `spec-writer` 에이전트가 정식 도입됐습니다. 스펙 작성도 계획 작성과 동일하게 "작성 → 자동 검토 → 통과 시 표시" 흐름으로 일관됩니다.

- **계획 작성 진입점이 하나로 통일됩니다.** 이전에는 계획 작성을 `/writing-plans` 스킬로 직접 호출하면 자동 검토 단계가 누락될 수 있었습니다. 이번 릴리스에서 그 스킬을 제거하고 `plan-writer` 에이전트 하나로 진입점을 통일해, 계획 작성은 항상 검토 단계를 거칩니다. (작성 절차 자체는 plan-writer 내부 문서로 옮겨져 그대로 보존됩니다.)

- **편집·Bash 훅이 조금 더 빨라집니다.** 매 편집/명령마다 도는 훅들이 Python 인터프리터를 불필요하게 여러 번 띄우던 것을 줄였습니다. 정상적인 python3 환경에서는 인터프리터 존재 확인을 위한 추가 실행을 생략하고(POSIX 한정 — Windows 진단 경로는 그대로 유지), 일부 훅의 중복 추출 호출을 한 번으로 합쳤습니다. 동작은 동일하고 지연만 줄어듭니다.

- **차단 메시지 생성이 더 안전해집니다(fail-closed 강화).** 위 속도 개선의 부수 효과로 "설치는 됐지만 깨진 python3" 가 차단 메시지(JSON) 생성 단계까지 도달할 수 있게 되어, 깨진 인터프리터가 차단을 우회시키지 못하도록 무결성 검증을 추가했습니다. 어떤 경우에도 차단은 유지되고(절대 fail-open 안 됨), 깨진 python3 일 때는 원인을 알려주는 진단 메시지가 표시됩니다.

> 버전 등급 메모: 신규 에이전트(`spec-writer`) 기준 권고는 minor 이나, 메인테이너 판단으로 patch(1.4.3) 로 릴리스 (versioning Rule A 는 advisory).

## v1.4.2 — 2026-06-01 (계획 기반 병렬 실행 + 자율 진행 시 리뷰 게이트 보호)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **여러 독립 작업을 계획에 선언한 의존 순서대로 병렬 실행합니다.** 새 `parallel-execute` 스킬이 활성 계획의 실행 전략(작업별 의존 관계·실행 모드·범위)을 읽어, 서로 의존하지 않는 편집 전용 작업들을 같은 작업 트리에서 서브에이전트로 동시에 돌리고, 서로 의존하거나 파일을 바꾸는 작업은 순서대로 실행합니다. 각 병렬 묶음이 끝날 때마다 메인 세션이 변경분을 검증·테스트·커밋합니다. 호스트가 병렬 실행을 지원하지 않으면 자동으로 순차 실행으로 내려갑니다. 함께 `plan-writer` 가 계획에 이 실행 전략을 작성하도록 확장됐습니다.

- **자율 진행 중에도 리뷰 게이트를 우회할 수 없습니다.** 이전에는 특정 자율 진행 흐름에서 코드 리뷰/보안 리뷰를 거치지 않고 커밋·테스트 게이트가 통과될 여지가 있었습니다. 이번 릴리스에서 그 우회 경로를 차단하고, 우회 시도는 감사 로그에 남도록 가드레일을 추가했습니다. 또 브랜치 전환·cherry-pick 으로 파일 수정 시각만 바뀐 경우를 정상 상황으로 인식해 거짓 차단을 줄였습니다.

## v1.4.1 — 2026-05-29 (응답 언어가 사용자 언어를 따라갑니다 + 리뷰 게이트 정확도)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **답변이 사용자가 쓰는 언어를 따라갑니다.** 이전에는 rein 이 매 턴 주입하는 규칙 본문이 한국어로 작성돼 있어, 영어(또는 다른 언어)로 설정된 프로젝트에서 영어로 질문해도 답변이 한국어로 쏠리는 경우가 있었습니다. rein 에 "한국어로 답하라"는 강제 지시는 없었지만, 매 턴 상시 주입되는 한국어 텍스트가 출력 언어를 한국어 쪽으로 끌어당기는 현상(soft anchoring)이 원인이었습니다. 이번 릴리스에서 매 턴 주입되는 짧은 규칙 2개를 영어로 바꿔 그 쏠림을 제거하고, **"사용자가 보낸 메시지의 언어로 답한다 — 단, Claude Code 의 명시적 언어 설정이나 상위 지시가 있으면 그것을 우선한다"** 는 출력 언어 정책을 응답 톤 규칙에 추가했습니다. Claude Code 의 `language` 설정으로 특정 언어를 고정한 사용자는 그 설정이 그대로 우선되어 영향이 없습니다. (rein 내부 규칙 전체 본문은 여전히 한국어로 유지됩니다 — 출력 언어 선택에만 적용되는 변경입니다.)

- **리뷰 게이트가 파일 조작만으로 거짓 차단하지 않습니다.** 이전에는 설계/스펙 리뷰 완료 표시가 파일의 수정 시각(mtime)을 기준으로 "리뷰 이후 내용이 바뀌었는지"를 판정했습니다. 그래서 브랜치 전환·cherry-pick·파일 회전처럼 **내용은 그대로인데 mtime 만 갱신**되는 경우에도 거짓으로 "미리뷰 상태"로 판정해, 무관한 코드 편집까지 연쇄로 차단되곤 했습니다. 이제 파일 내용 해시를 기준으로 판정하므로, 내용이 실제로 바뀌었을 때만 재리뷰를 요구합니다.

- **테스트 파일 편집이 미리뷰 스펙 게이트에 막히지 않습니다.** `tests/` 경로 편집은 "미리뷰 설계 문서" 차단 게이트의 대상에서 제외되어, 설계 문서와 무관한 테스트 추가·수정이 더 이상 막히지 않습니다.

- **커밋 가드와 코드 리뷰 보조 도구가 더 견고해집니다.** 커밋 메시지 검증 정규식이 정밀해져 정상 메시지의 오탐을 줄였고, 코드 리뷰 보조 도구가 번들 라이브러리를 찾지 못하면 조용히 통과하지 않고 안전하게 실패(fail-closed)하도록 바뀌었습니다.

## v1.4.0 — 2026-05-28 (응답 톤 강화 + 병렬 worker 메커니즘 + 검토 게이트 정확도 + 응답 속도)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **어시스턴트 답변이 한층 평문화됩니다 — 내부 식별자가 사용자 대화에서 사라집니다.** 새 응답 톤 규칙이 `stamp`, `verdict`, `.codex-reviewed`, `approved_by_user`, `security_tier`, Scope ID 같은 내부 ID 를 채팅 본문에 노출하지 못하게 하고, 일관된 평문 번역 테이블을 적용합니다 (예: "검토 완료 표시를 남겼습니다", "통과 / 수정 필요 / 반려", "보안 검토 강도: 가벼움 / 표준 / 깊음"). 완료·진행 보고는 "방금 한 것 → 결과 → 다음 단계" 흐름으로 정형화되고, 사용자 확인 질문에서도 내부 식별자가 빠집니다. `trail/index.md` / `trail/inbox/` / `MEMORY.md` 본문을 원본 그대로 인용하지 않고 평문으로 풀어쓰는 규칙도 명시됩니다. v1.3.8 의 "응답 톤" 변경이 톤 가이드의 첫 도입이었다면, 이번은 그것을 "허용+풀이" 에서 "절대 금지+평문 번역" 으로 강화한 단계입니다.

- **에이전트 보고 메시지가 평문으로 통일됩니다.** plan-writer / feature-builder / feature-builder-fix / feature-builder-refactor / feature-builder-worker / security-reviewer 모든 에이전트에 `## 사용자 보고 방식` 섹션이 추가되어, 작업 착수 / 완료 / 차단 / 발견 사항을 평문 템플릿으로 안내합니다. plan-writer 의 기존 영문 handoff 메시지 (`Plan complete: ...`, `Spec review: PASS ...`, `Stamp created: ...`) 는 내부 운영 기록 전용으로 분리되어 채팅 본문에는 더 이상 노출되지 않습니다. 작업 진행 차단 시 hook 안내도 marker 파일 경로에 평문 설명을 병기하는 형태로 다듬어졌습니다.

- **라우팅 추천이 두 층 채팅 표현으로 바뀝니다.** 작업 시작 시 사용자에게 보여지는 라우팅 추천이 평문 한 줄 ("[작업명] 을 진행하겠습니다. 계획: [한 문장 요약]. 이 방향으로 진행할까요?") 다음에 상세 라우팅 정보 (담당 에이전트 / 보조 스킬 / 외부 자료 / 근거) 가 따라오는 두 층 구조로 정리됩니다. 어떤 에이전트가 선택됐는지 사용자가 승인 전에 명확히 볼 수 있도록 상세 정보는 유지되며, DoD 파일의 저장 형식 (`agent:` / `skills:` / `approved_by_user:`) 자체는 변경 없습니다.

- **병렬 worker 실행 메커니즘이 정착됩니다 — `parallelizable: true` plan + worktree 격리 worker 에이전트 정식 도입.** plan 작성 시 `## 실행 전략` 섹션과 `parallelizable: true` 플래그를 명시하면, plan-writer 가 파일 소유권 기반으로 worker scope 를 자동 분할하고, 새 `feature-builder-worker` 에이전트 (`isolation: worktree` frontmatter) 가 격리된 git worktree 에서 동시에 코딩합니다. worker 가 종료할 때 `.rein/worker-result.json` 으로 `scope_status: completed` 또는 `blocked_<reason>` (architectural_contract_conflict / missing_dependency_file / test_contract_stale / scope_mismatch / context_exhaustion 5 종) 을 보고하면 parent 가 cherry-pick / fallback / split / scope-expand 로 분기합니다. `parallelizable: true` 인 plan 의 소스 편집은 worker dispatch 안에서만 허용되도록 편집 게이트가 강제됩니다 — 일반 (`parallelizable` 미지정 또는 `false`) plan 에는 영향 없습니다.

- **검토 누락이 사라집니다 — orphan 검토 표시 백스톱.** spec-review 게이트가 종전에는 검토 대기 표시(`.pending`) 가 있을 때만 stale 여부를 검사했지만, 이제 검토 대기 표시 없이 `.reviewed` 만 남은 경우에도 스펙 본문의 수정 시각과 검토 시각을 비교해 stale 판정 → 차단합니다. 회고 stamp (`reviewer: retrospective-shipped-<tag>`) 는 예외로 통과되어 v1.0.0 이전 legacy 문서 워크플로는 그대로입니다.

- **응답 속도가 빨라집니다 — 정책 로더 shell rewrite.** 매 편집 직후 발화되던 변경 파일 advisory (post-edit-meta-check) 의 p95 가 ~210-230ms (목표 150ms 대비 초과) 였던 것을, 정책 로더를 shell + heredoc 으로 재작성해 Python cold-start 횟수를 줄였습니다. 사용자 체감으로는 편집 후 advisory 출력 사이 지연이 줄어듭니다. 동작 자체는 동일합니다.

- **`rein update` 의 plugin-mode 안내가 영문으로 추가됩니다.** v1.0.4 의 plugin-first 재구조화 이후 `rein update` 가 일부 시나리오에서 어디로 가야 하는지를 한국어로만 안내하던 부분에 영문 redirect notice 가 같이 출력됩니다. 비한국어권 사용자가 잘못된 경로로 갈 가능성이 줄어듭니다.

## v1.3.8 — 2026-05-27 (plugin install hotfix + 작업 라우팅 안내 + 변경 파일 추적 advisory + 응답 톤 + 자동모드 marker)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **`/plugin install rein@rein` 이 다시 됩니다** — 최신 Claude Code 가 rein plugin 의 manifest(`plugin.json`) 에 공식 스키마에 없는 키 하나를 발견하면 install 자체를 거부하던 문제를 수정했습니다. 기존 install 사용자에게는 영향 없습니다. (사용자 보고에 따른 hotfix — v1.0.0 이래 잠재해 있었으나 메인테이너 환경에서는 통과되어 미탐지)

- **세션 시작 직후 작업 유형 → agent/skill 빠른 안내가 나옵니다** — 새 `routing-map` 규칙이 매 세션 시작 컨텍스트에 자동 포함되어, DoD 작성 직후 어떤 에이전트와 스킬을 쓸지 7행 표로 한눈에 확인할 수 있습니다. 상세 매칭 절차는 기존 routing-procedure 규칙 그대로 (동작 변경 없음).

- **DoD 작성 후 편집 중 "예상 외 파일" 안내가 나옵니다** — 새 `post-edit-meta-check` advisory 가 DoD 의 `## 변경 파일` 섹션(있으면)을 현재 작업 폴더의 dirty diff 와 비교해, 목록에 없는 파일이 편집되면 다음 turn 의 advisory 본문에 알려줍니다. 모든 평가는 차단이 아니라 안내이며, 결과는 `trail/inbox/<날짜>-meta-check.jsonl` 에 누적되어 사후 회고가 가능합니다. 기본 모드는 `auto` — DoD 에 `## 변경 파일` 섹션이 없으면 자동으로 건너뜁니다 (기존 DoD 무영향). `.rein/policy/meta-check.yaml` 의 `enabled: true|false|auto` 로 동작 조정 가능.

- **신규 DoD 에 `## 변경 파일` 섹션을 권장합니다** — 5 종 DoD 작성 에이전트 (feature-builder / feature-builder-fix / feature-builder-refactor / plan-writer / researcher) 의 안내에 의무 항목으로 추가됐고, operating-sequence Step 2 의 의무 섹션 명단에도 등재됐습니다. 기존 DoD 는 위 advisory 가 silent 처리하므로 영향 없습니다.

- **어시스턴트 답변이 평이한 문장으로 출력됩니다** — 새 `response-tone` 규칙이 매 사용자 turn 직후 컨텍스트에 자동 포함되어, 답변 첫 줄에 "지금 무엇을 묻는지 / 제가 무엇을 하려는지" 평문 1줄, 끝 줄에 "다음에 무엇을 할지" 1줄, rein 내부 약어 첫 등장 시 괄호 풀이, `MEMORY.md` / `trail/index.md` / `trail/inbox/` 원본 인용 대신 평문 재진술을 따르도록 합니다. 이전 "비서톤" 작업은 hook 차단 메시지 4 표면 한정이었지만 본 변경은 어시스턴트 응답 톤 자체에 적용됩니다.

- **자동모드 marker 로 incident 알림을 한시적으로 끌 수 있습니다** — 새 토글 스킬 `/rein:auto-mode-on` (또는 직접 `mkdir -p .rein && touch .rein/auto-mode.flag`) 로 marker 를 켜면, 자율 진행 (`/loop`, multi-step autonomous cycle) 중 매 turn 발화하던 `incidents-to-rule` 권고 / pending incident 안내 / session-end block 이 모두 silent 처리됩니다. block 우회 이력은 `trail/incidents/auto-mode-bypass.log` 에 timestamp + 이유 1줄씩 누적되어 사후 추적 가능합니다. 종료 시 `/rein:auto-mode-off` 또는 `rm -f .rein/auto-mode.flag`.

## v1.3.7 — 2026-05-24 (프로젝트 위치 탐지 보안 하드닝 — git 환경 오염 차단 전면화)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **오염된 git 환경변수로 엉뚱한 저장소가 프로젝트로 인식되는 경로를 전부 닫았습니다** — v1.3.6 에서 일부 경로(bootstrap-check)에만 적용했던 보호(오염된 `GIT_DIR` 등이 엉뚱한 저장소를 프로젝트 루트로 잡지 못하게 차단)를, 프로젝트 위치를 탐지하는 **나머지 모든 경로**(작업 선택 resolver, 세션 상태, trail 보호 게이트, 리뷰 스탬프 기록, legacy 정리 도구)로 확장했습니다. 특히 trail 보호 게이트의 한 경로에서는 오염된 환경 + 가짜 저장소의 "비활성 표시"로 게이트가 우회될 수 있던 가능성을 닫았습니다. 일반 사용에는 영향이 없는 방어 강화입니다.

## v1.3.6 — 2026-05-23 (리뷰 게이트 정확도 + job stop 상태 + bootstrap 보안)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **새 설계/플랜 문서의 첫 리뷰가 무관한 작업 때문에 잘못 막히지 않습니다** — 이전엔 새 design/plan 을 처음 `/codex-review` 할 때, 진행 중이던 다른 작업의 활성 DoD 가 리뷰 컨텍스트로 끌려 들어가 그 작업의 항목들이 "누락"으로 보고되며 거짓 NEEDS-FIX 가 났습니다. 이제 새 설계/플랜 리뷰는 무관한 활성 DoD 를 끌어오지 않고, 리뷰 대상 문서 자체에만 집중합니다.
- **`rein job stop` 이 종료 상태를 제대로 기록합니다** — 이전엔 `rein job stop` 이 프로세스는 종료시키면서도 잡 상태 파일을 `running` 그대로 남겨, 멈춘 잡이 계속 실행 중인 것처럼 보였습니다(특히 일부 환경의 단일 PID 종료 경로). 이제 stop 이 종료 상태(`killed` + 종료 코드)를 직접 기록합니다. 정상 종료된 잡의 실제 결과는 덮어쓰지 않습니다.
- **bootstrap 경로의 git 환경 오염 차단이 더 넓어집니다** — rein 의 프로젝트 위치 탐지가 직접 CLI 호출(stdin 없는) 경로에서도, 오염된 git 환경변수(`GIT_DIR` 등)가 엉뚱한 저장소를 프로젝트로 인식하지 못하도록 차단합니다. 기존엔 훅 경로에만 적용되던 보호를 이 경로까지 확장했습니다.

## v1.3.5 — 2026-05-22 (리뷰 게이트 우회 차단 + 마커/스탬프 무결성)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **리뷰가 끝난 설계/플랜 문서를 다시 고치면 재리뷰를 강제합니다** — 이전엔 리뷰 완료 표시(`.reviewed`)가 한 번 생기면, 같은 문서를 다시 편집해도 그 표시가 남아 있어 게이트가 통과시켰습니다. 즉 미리뷰 변경분으로 소스 편집이 풀리는 우회가 가능했습니다. 이제 (1) 문서를 다시 편집하면 이전 리뷰 표시가 자동으로 무효화되고, (2) 게이트가 "편집 시각 > 리뷰 시각"이면(또는 시각 정보가 손상/누락이면) 미리뷰로 간주해 차단합니다.
- **활성 작업 마커가 프로젝트 밖 경로를 가리키면 거부합니다** — 활성 DoD 마커(`.active-dod`)가 가리키는 경로에 대해, 세션 시작 청소 훅뿐 아니라 작업 선택 단계에서도 경로 검증(절대경로·`..`·메타문자·심볼릭링크 탈출 차단)을 적용합니다. 오염된 마커가 프로젝트 외부 파일에 차단 권위를 얻는 경로를 닫았습니다.
- **리뷰 스탬프의 비교 기준(diff_base)을 검증합니다** — `/codex-review` 가 직전 리뷰 스탬프에 기록된 비교 기준 커밋을 채택할 때, 그 커밋이 실재하고 현재 HEAD 의 조상인지 확인합니다. 실재하지 않거나 다른 브랜치/orphan 커밋이면 안전하게 직전 커밋(HEAD~1)으로 대체합니다.

> Same-day patch: v1.3.4 와 같은 날 릴리스 — 사용자 지시에 따른 릴리스(긴급 핫픽스 아님). 세 항목 모두 코드리뷰로 발견한 게이트 무결성 보강.

## v1.3.4 — 2026-05-22 (보안 게이트 정합성 + 세션 종료 게이트 안정성)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **보안 리뷰 stamp 면제가 더 엄격해집니다** — 이전엔 commit 게이트의 보안 stamp 면제(`security_tier: light`)가 `.active-dod` marker 가 명시적으로 가리키는 DoD(Tier 1)뿐 아니라, marker 부재 시 mtime 으로 추정한 fallback DoD(Tier 2)까지 수용했습니다. fallback 은 advisory(non-blocking) 권위라 "보안 리뷰 없이 commit 허용" 같은 차단 결정의 근거로 부적절했습니다. 이제 이 면제는 `.active-dod` 가 명시적으로 가리키는 Tier 1 DoD 에서만 적용됩니다. codex 리뷰 stamp(`.codex-reviewed`)는 tier 와 무관하게 항상 필요합니다(불변).
- **비밀파일 읽기 차단이 더 넓어집니다** — safety guard 의 비밀값 읽기 차단(P8)이 이전엔 `cat` / `head` / `tail` / `less` / `more` / `python` / `node` 만 탐지했습니다. 이제 `grep` / `awk` / `sed` / `jq` / `cut` 으로 비밀파일을 읽는 경로도 차단합니다. 안전 템플릿(예시 키만 담긴 파일)은 그대로 통과하며, 따옴표로 모호해진 패턴은 보안 우선으로 보수적 차단(deny-by-default)합니다.
- **세션 종료 게이트가 더 안정적입니다** — (1) 차단된 편집이 남긴 stale resolver 캐시(`.rein/cache/hook-resolver/`)를 세션 종료 시 24시간 기준으로 정리합니다(시각 불명 항목은 보존). (2) stale DoD 경고에서 이미 완료된(inbox 기록이 매칭되는) DoD 는 제외해 불필요한 경고가 사라집니다. (3) POSIX 호환성 수정 — 미해결 incident 카운트의 정수 검사를 bash 전용 문법에서 POSIX `case` 로 교체.

내부 변경 (사용자 영향 없음):

- scaffold-mode 용어를 제거하고 테스트/주석을 plugin-mode fixture 로 일원화.
- 문서 추가 — README 에 "How Rein differs from Claude Code workflows" 비교 섹션, `docs/architecture.md`(hook lifecycle 맵 + 게이트별 enforcement 표), `docs/policy-model.md`(governance 모델, 선언형 정책 방향은 roadmap 으로 표기).

## v1.3.3 — 2026-05-20 (rule injection 경량화 + background-jobs advisory cold-path skip)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **매 user turn / 매 Bash 호출 마다 들어가던 rule 본문이 약 91~92% 줄어듭니다** — 이전엔 `user-prompt-submit-rules.sh` 가 매 turn 마다 `answer-only-mode.md` 본문 (~7 KB), `pre-tool-use-bash-rules.sh` 가 매 Bash 호출마다 `background-jobs.md` 본문 (~6 KB) 을 그대로 inject 했습니다. 이제 두 hook 은 short summary (`plugins/rein-core/rules/short/{answer-only-summary,background-jobs-summary}.md`, 각 ≤ 600 B) 만 inject 합니다. SessionStart 의 4-rule (code-style / security / testing / operating-sequence) full inject 는 그대로이며, 원본 rule 본문도 plugin source 에 보존됩니다 (필요 시 직접 read 가능). 차단 동작은 변하지 않습니다.
- **일반 Bash 호출에서 advisory rule hook 이 더 이상 spawn 되지 않습니다** — `pre-tool-use-bash-rules.sh` (background-jobs 환기 inject) 가 이제 hot-path 명령 (`pytest`, `npm test`, `yarn test`, `pnpm test`, `npm run test`, `cargo build`, `docker build`, `playwright`, `make`, `tsc`, `python -m pytest`, `npx jest`, `npx vitest` — bare + args 둘 다) 에만 spawn 됩니다. `ls`, `git status`, `grep` 같은 일반 명령에서는 이 hook 이 호출되지 않아 cold-path 응답이 빨라집니다. 안전 가드 (`pre-bash-safety-guard.sh`) 와 bootstrap check (`pre-tool-use-bash-bootstrap-gate.sh`) 는 항상 실행 — 차단 동작은 그대로입니다.

내부 변경 (사용자 영향 없음):

- 2026-05-20 미처리 incident 3건 declined 처리 + 원본 삭제 (`auto-pre-bash-guard-712c619297124005`, `auto-pre-edit-dod-gate-bef187256cf7608e`, `auto-pre-edit-dod-gate-eee46f3711b27315`). 모두 hook 의 의도된 차단 동작이라 새 규칙 불필요.

## v1.3.2 — 2026-05-19 (Claude Code v2.1.144 hook 기능 채택 + 기록 버그 수정)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **테스트 실행이 더 이상 리뷰 stamp 를 요구하지 않습니다** — 이전엔 `pytest` 등 테스트 실행 자체가 코드 리뷰 stamp 없이는 차단돼 TDD 의 red→green 루프가 구조적으로 불가능했습니다. 이제 테스트 실행은 게이트 대상이 아니며, 리뷰 stamp 게이트는 `git commit` 에만 적용됩니다.
- **feature-builder 서브에이전트 완료 시 코드 리뷰 안내가 자동으로 뜹니다** — 새 PostToolUse hook 이 feature-builder 계열 에이전트의 작업 완료를 감지해 `/codex-review` 실행을 안내합니다 (리뷰 대기 마커가 있을 때).
- **라우팅 추천에 보안 등급·복잡도 힌트가 추가됩니다** — `## 라우팅 추천` 에 `security_tier`(light/standard/deep) 와 `complexity`/`model_hint`/`effort_hint` 필드가 생깁니다. `security_tier: light` + 사용자 승인 시 보안 리뷰 stamp 가 면제됩니다 (보안 키워드 없는 소규모 변경 한정 — 불명확하면 standard 로 fail-closed).
- **feature-builder 가 작업 유형별로 분화됩니다** — `feature-builder`(신규 기능) / `feature-builder-fix`(버그 수정) / `feature-builder-refactor`(리팩터링) 3개로 나뉘고, DoD 키워드로 적합한 변형이 추천됩니다.
- **commit/안전 게이트 hook 이 둘로 분리됩니다** — 기존 `pre-bash-guard` 가 `pre-bash-safety-guard`(모든 Bash 호출에 상시 — `.env` 접근·파괴적 git 차단)와 `pre-bash-test-commit-gate`(테스트·커밋 명령에만 실행)로 나뉩니다. **차단 동작과 범위는 불변**이며, 일반 Bash 호출에서 불필요한 hook 실행이 줄어듭니다.
- **세션 시작이 약간 빨라집니다** — incident 집계 subprocess 호출이 3회에서 1회로 통합됩니다.

Internal (메인테이너 dev 환경, 사용자 무관):

- post-write-* sub-hook 4종을 post-edit-* 로 rename (dispatch 동작 불변).
- project-dir 해소 / codex-review wrapper 의 경로 sanity 강화 (PD-1·PD-2).
- 17 정책 차단지점(P1-P11·I1-I6)을 분리된 두 게이트에 전수 재배정, 공통 infra lib 추출.

> 변경 분류상 새 hook·에이전트·라우팅 필드 추가는 minor(v1.4.0)에 해당하나, 메인테이너 판단으로 patch(v1.3.2)로 릴리즈한다.

## v1.3.1 — 2026-05-18 (hook 비서 톤 2단계 + 분류기 정밀화 + 스마트 라우팅 정리)

`rein update` 후 사용자 세션에서 바뀌는 것:

- **hook 차단 사유가 사용자 언어로 전달됩니다** — `pre-bash-guard` 의 정책 차단(파이프 쉘 실행, 커밋 메시지 포맷 위반, `.env` 파일 접근, 파괴적 git 명령, 리뷰 미완료 등 11지점)이 차단 사유를 Claude 에게 구조화해 전달합니다. Claude 가 그 사유를 사용자 대화 언어로 풀어 설명하므로, 영어 stderr 한 줄 대신 "무엇이 왜 막혔고 어떻게 풀지" 안내를 받습니다.
- **차단·경고 메시지가 비서 톤으로 재작성됨** — 사용자 대면 hook 메시지(JSON 차단 안내 / Stop hook 차단 / SessionStart 배너 / 잔류 stderr)가 대문자 명령형("BLOCKED:") 대신 자연스러운 "무엇 → 왜 → 어떻게" 문장으로 바뀌었습니다.
- **pre-bash-guard 의 명령 차단 판정이 정밀해졌습니다** — 이전엔 명령 문자열 어디에든 위험 키워드(파괴적 git, `.env` 접근 등)가 보이면 차단했으나, 이제 실제 실행되는 명령 절(clause) 단위로 판정합니다. `echo` 인자에 들어간 안내 문자열처럼 무해한 명령이 잘못 차단되던 false positive 가 줄었고, 리뷰 후 정상 코드 재수정이 과하게 막히던 동작도 해소됐습니다. 차단해야 할 명령의 차단 범위는 그대로입니다.
- **스마트 라우팅이 세션 주입 목록 기반으로 동작합니다** — 작업에 맞는 agent/skill/MCP 추천이 Claude Code 가 세션마다 제공하는 사용 가능 목록을 직접 활용합니다. 이전 인벤토리 스캐너는 Claude Code 의 plugin 저장 구조와 어긋나 빈 결과만 내던 회귀가 있어 폐기했고, SessionStart 의 skill/MCP 가이드 주입도 함께 제거됩니다.
- **차단 동작 자체는 불변** — 막히던 명령은 그대로 막히고 차단 범위·조건도 동일합니다. 바뀐 것은 차단 사유의 전달 표면(stderr → Claude 응답)과 오인 차단 정확도입니다.

Internal (메인테이너 dev 환경, 사용자 무관):
- 중앙 JSON deny emitter 3슬롯 재설계 (`<신뢰된_사유> <reason_code> <격리할_입력>`), reason_code 필수화, fail-closed 불변식 보존.
- `pre-bash-guard` 정책 차단 11지점 `exit 0 + JSON deny` 전환, 인프라 무결성 5지점 + 신규 emitter-부재 가드는 `exit 2` 유지.
- need-to-confirm FU-1~4 묶음 (`ed8d690`): `incidents-to-rule` skill 의 AGENTS.md 부재 분기, `mirror-to-public` workflow 의 AGENTS.md 메인테이너 라인 public strip, spec-review stamp resolver 경로 fix, pre-bash-guard 5개 분류기 + post-edit-hygiene 의 명령 절-앵커링.
- 스마트 라우팅 A+ (`0a908a7`): 인벤토리 스캐너 (`rein-scan-skill-mcp.py` / `rein-generate-skill-mcp-guide.py`) 폐기, `routing-procedure.md` 를 dev-only `orchestrator.md` 의 발견/매칭 알고리즘 이식으로 self-contained 화.
- `tests/hooks` + `tests/rules` pre-existing 드리프트 23 suite 정리 (폐기 `.claude/hooks/` 경로 repoint, stale 단언 갱신, 미구현 migration 테스트 제거, bootstrap fixture 재설계). 전체 회귀 ALL SUITES PASSED.

## v1.3.0 — 2026-05-15 (Bootstrap gate deadlock fix + auto-bootstrap)

v1.2.0 release 후 다른 프로젝트 fresh install 환경에서 SessionStart 의 "bootstrap 미완료" 안내 명령이 Bash gate 자체에 차단되어 회복 불가능한 deadlock 이 보고됐습니다. `${CLAUDE_PLUGIN_ROOT}` 가 사용자 shell 에서 expand 안 되어 안내 명령이 실패하고, Stop hook 이 무한 반복되어 세션 진행 불가였습니다. `rein update` 후 사용자 세션에서 바뀌는 것:

- **세션 시작 시 자동 bootstrap** — git repo + safe path 인 경우 SessionStart hook 이 자동으로 `.rein/project.json` + `trail/index.md` + `.gitignore` 를 생성합니다. 사용자는 별도 명령 실행 없이 첫 세션부터 작업 시작 가능. 완료 시 한 줄 알림 inject ("rein: bootstrap completed automatically — created trail/ and .rein/project.json in <path> (version 1.3.0)").
- **Degraded mode 도입** — git binary 미설치, non-git directory, `REIN_NO_AUTO_BOOTSTRAP=1` opt-out, bootstrap 안전 거부 시 rein governance gate 가 자동으로 통과 모드로 전환됩니다. Claude Code 자체는 평소대로 동작 + 상황별 1줄 안내 (git 미설치 시 macOS/Debian/Fedora/Arch/Windows 별 설치 명령 안내 포함). marker: `.claude/cache/.rein-session-degraded`. 사용자가 직접 bootstrap 한 뒤 다음 세션에서는 marker 자동 정리.
- **Bash gate self-block 해소** — bootstrap 미완료 상태에서도 `python3 .../rein-bootstrap-project.py --project-dir ...` 명령이 통과합니다 (allow-list 추가). 어제 deadlock 의 회복 경로 확보.
- **Trail edit gate path-scoped 화** — 기존엔 bootstrap 미완료 시 모든 Edit/Write 가 차단됐지만, 이제 `trail/` 외 파일 편집은 통과합니다 (`scripts/foo.py` 같은 일반 파일은 봉쇄되지 않음).
- **Stop hook 무한 루프 해소** — bootstrap 미완료 또는 degraded 모드에서 Stop hook 의 incident gate 가 즉시 통과합니다. fresh install 후 Stop hook 봉쇄 가능성 제거.
- **Bootstrap 안내 메시지 portable** — guidance 가 `${CLAUDE_PLUGIN_ROOT}` literal 대신 expanded 절대 경로로 표시됩니다. 사용자가 메시지를 복사해 shell 에 그대로 붙여넣어도 동작.
- **`.rein/project.json` 의 version 이 plugin.json 과 자동 동기화** — bootstrap helper 가 plugin manifest 의 version 을 동적으로 읽습니다. 이전엔 default `"1.0.0"` 으로 작성되어 stale 가능성 (v1.2.0 install 도 1.0.0 marker 작성).
- **`incidents-to-rule` / `incidents-to-agent` skill 의 명령 예시 portable resolver 사용** — `${CLAUDE_PLUGIN_ROOT}` 노출 대신 `claude plugin path rein-core` 또는 `$HOME/.claude/plugins/marketplaces/rein/...` fallback. 사용자가 skill instruction 을 그대로 실행해도 정상 동작.

Internal (메인테이너 dev 환경, 사용자 무관):
- 신규 helper `plugins/rein-core/hooks/lib/degraded-check.sh` — degraded marker lifecycle 관리 (`rein_is_degraded` / `rein_write_degraded` / `rein_clear_degraded` 3 함수).
- BG-C 의 degraded marker lookup 이 stdin.cwd git-root walkup 수행 — monorepo subdir 에서도 marker 정확히 인식.
- `tests/hooks/lib/test-harness.sh` 가 Option C Phase 3 후 plugin path (`plugins/rein-core/hooks/`) fallback 지원.
- 신규 gate fixtures + BG-1 contract (trail/ + `.rein/project.json` 둘 다 require) 와 test 일관성 확보. 총 48/48 fixtures PASS.
- 통합 codex review round 2 PASS (round 1 NEEDS-FIX → fix → round 2 PASS) + security review PASS.

## v1.2.0 — 2026-05-14 (Scaffold→plugin migration gap fix)

v1.1.3 Option C 이후 plugin SSOT 와 사용자 ship 표면 사이에서 발견된 9 drift + 메인테이너 분석 추가 6건을 한 cycle 로 묶어 해소. `rein update` 후 사용자 세션에서 바뀌는 것:

- **`/codex-review` 등 hook 의 helper 호출이 plugin-install 환경에서 안정** — 새 `resolve_helper_script` 가 `${CLAUDE_PLUGIN_ROOT}/scripts/` 우선, `${PROJECT_DIR}/scripts/` fallback. 사용자 repo 에 scaffold 가 없어도 plugin source 의 helper 가 즉시 발견됩니다 (이전엔 일부 hook 이 hardcoded `scripts/...` 를 가리켜 plugin-only 사용자에서 "BLOCKED: helper not found" 가능).
- **Bootstrap 이 사용자 repo 에 default `.claude/security/profile.yaml` 만 생성** — 기존엔 plugin 에 security rules 가 ship 되지 않아 security-reviewer 가 사용 불가했습니다. 이제 plugin 이 `security/rules/{base,standard}.md` 를 ship 하고, bootstrap 은 profile.yaml 만 생성 (rules 본문은 plugin source 에 머묾, 사용자가 직접 override 가능).
- **Bootstrap 완료 판정 false positive 제거** — `trail/` 디렉토리만 있고 `.rein/project.json` marker 가 없으면 이제 "bootstrap 미완료" 로 안내합니다 (이전엔 stray `trail/` 만 있어도 silent 통과 → 실수로 미완료 상태에서 작업 진행 가능).
- **DoD 작성 후 routing 절차 자동 안내** — `## 라우팅 추천` 섹션이 없는 DoD 작성 시 PostToolUse hook 이 routing-procedure rule body 를 additionalContext 로 자동 inject. `pre-edit-dod-gate.sh` 가 stderr 로 약속하던 "PostToolUse hook 이 자동 inject" 가 실제로 동작.
- **Skill/MCP 인벤토리 가이드 plugin 화** — SessionStart 시 plugin 의 scanner + generator 가 동작 + 가이드 경로가 rein-state-paths 로 routing. plugin install 환경에서 가이드 파일이 정상 생성/갱신.
- **Incident automation helper 4개 plugin ship** — `incidents-to-rule` / `incidents-to-agent` skill 의 `rein-aggregate-incidents.py` / `rein-stop-emit-block.py` / `rein-mark-incident-processed.py` / `rein-mark-agent-candidate.py` 호출이 plugin path 우선. 사용자 repo 에 scaffold 없이도 incident 분석 동작.
- **`feature-builder` / `researcher` agent description 명료화** — 폐기된 workflow 파일 reference 제거 + 작업 유형별 핵심 원칙 (fix-bug reproduce-first, add-feature 기존 패턴 우선, build-from-scratch skeleton+vertical-slice) inline.
- **SessionStart 시 operating-sequence rule 자동 inject** — DoD→routing→implement→codex-review→security-review→fix→test→inbox→index 11-step 압축 표가 매 세션 추가 (advisory).
- **Publish 직전 plugin.json ↔ rein.sh VERSION mismatch 자동 검출** — `rein-publish.sh` 가 두 버전 불일치 시 abort.

Internal (메인테이너 dev 환경, 사용자 무관):
- `.claude/rules/branch-strategy.md` 의 ✅ 포함 / ❌ 제외 표 정정 (Option C 후 plugin SSOT 표현).
- 잔존 fix 9건 (F1 scanner plugin-aware refactor + F2/F4 pre-edit-dod-gate hardcoded paths + F3 test bundle doc drift + F5 codex-review wrapper layout probe + F6 plugin mirror sync + F7 bootstrap-check English message + F8 fixture G(b) BG-1 contract + F9 stale test skip).
- 회귀 차단: `tests/scripts/run-all.sh` ALL SUITES PASSED (13 helpers sha256 parity, 17/17 bootstrap-check fixtures, 6/6 resolver unit, 7/7 session-start-bootstrap, version-parity 1.2.0).

## v1.1.3 — 2026-05-14 (Option C — plugin SSOT 단독 + dogfood model)

v1.1.0~v1.1.2 동안 plugin-first 전환을 마쳤지만, plugin source (`plugins/rein-core/`) 와 메인테이너 dev overlay (`.claude/`) 가 sha256-mirror 관계로 양쪽에 같은 hooks/skills/agents 가 중복 보유되어 drift 위험 + tarball 사이즈 부담이 누적됐습니다. v1.1.3 은 **plugin SSOT 단일화 + 메인테이너 dogfood install** 전환을 마치고 그 결과를 ship 합니다. `rein update` 후 사용자 세션에서 바뀌는 것:

- **`design-plan-coverage` rule body 정확화** — SessionStart 시 plugin 이 inject 하는 rule 본문에 `## 행동 강령` summary + behavior-level Scope ID v2 의 acceptable/non-acceptable 예시 + Stage 1/2/3 enforcement 표가 모두 포함됩니다. 사용자 plan 작성 시 더 명확한 contract 가이드.
- **SessionStart banner path 정확화** — banner 의 `answer-only-mode.md` reference 가 `${CLAUDE_PLUGIN_ROOT}/rules/...` 로 재작성. installed plugin cache 에서도 정확한 경로 표기 (이전엔 dev-only path 표시).
- **Plugin tarball 사이즈 감소** — `plugins/rein-core/docs/rules/` 의 4 mirror 파일 (legacy-shipped-pending, background-jobs, design-plan-coverage, subagent-review) 폐기. install size + cache footprint 약간 감소. 사용자 hook 동작 변화 없음 (rule body inject 는 `plugins/rein-core/rules/` 가 source).

영향 없음: `rein` CLI 명령 표면 / hook 차단 정책 / 사용자 ship 표면 자체 변화 없음. 본 release 는 patch — 메인테이너 환경의 큰 변경 (`.claude/{hooks,skills,agents}/` overlay 폐기 → plugin SSOT 단독) 이 사용자에게는 거의 invisible.

Internal (메인테이너 dev 환경, 사용자 무관):
- `.claude/hooks/`, `.claude/skills/`, `.claude/agents/` overlay 전체 폐기. plugin source 가 단독 SSOT. 메인테이너는 `/plugin install rein@rein` 으로 dogfood 운영.
- `scripts/rein-check-plugin-drift.py` 가 boundary (`.claude/rules/` shared rule mirror 금지) + parity (plugin ↔ dev tree sha256 동일) + validation (mandate section + inject envelope + hooks.json schema) 3 layer 통합 도구로 재작성. `scripts/rein-validate-plugin-rules.py` 는 wrapper-only shim (backward compat).
- `tests/scripts/test-rein-check-plugin-drift-boundary.sh` 신규 (8 test, post-cleanup invariant + isolated 7-mirror fixture). `tests/hooks/test-{background-jobs,design-plan-coverage,subagent-review,legacy-pending-heal}-registered.sh` 갱신 (hooks.json nested schema + plugin source path redirect).
- `.claude/rules/branch-strategy.md` 의 ✅ 포함 / ❌ 제외 표를 plugin SSOT 중심으로 재작성. 9 GitHub workflow 모두 분류 (public 도달 2 + maintainer-only mirror-strip 7). `.github/workflows/plugin-drift-check.yml` 의 transitional `--skip-boundary` 제거.
- 본 cycle 의 검증 결과 (sandbox dogfood inject byte > 0, trigger count == 1 deterministic, cache rebuild 검증 5/5 PASS) 모두 `trail/decisions/2026-05-13-option-c-sandbox-verification.md` + `trail/decisions/2026-05-14-plugin-cache-verification-evidence.md` 에 영구 보관.

## v1.1.2 — 2026-05-12 (Plugin self-containment hotfixes)

v1.1.0 plugin-first 전환 이후 사용자 repo 에서 scaffold 잔재를 정리한 환경에서 발견된 plugin 자체 결함 2건 hotfix. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **`/codex-review` 가 scaffold 없는 사용자 프로젝트에서도 동작** — wrapper (`rein-codex-review.sh`) 가 더 이상 사용자 repo 의 `.claude/hooks/lib/select-active-dod.sh` 를 source 하지 않습니다. 자기 plugin tree 의 sibling 번들 lib 를 사용 (plugin self-containment). scaffold 를 지운 plugin-first 사용자도 `/codex-review` 정상 호출.
- **monorepo subdirectory 에서 Bash 차단 false-positive 해소** — PreToolUse:Bash hook 의 `bootstrap-check.sh` 가 Claude Code envelope 의 `cwd` (Bash 도구의 셸 CWD) 를 그대로 project_dir 로 채택하던 동작 변경. monorepo 에서 `cd apps/web` 한 뒤 모든 Bash 호출이 차단되던 증상 해결. 이제 `git -C <stdin.cwd> rev-parse --show-toplevel` 로 git root 까지 walk up 해서 부트스트랩 contract 와 정렬.
- **nested .git 경계 존중** — sub-project 가 자체 `.git/` 가진 경우 walk-up 은 그 nested boundary 에서 멈춥니다 (outer monorepo root 로 escape 안 함).
- **git env redirection 차단** — bootstrap-check 의 새 git 호출은 `GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE` 를 unset 한 상태로 실행. caller 환경의 git env 가 walk-up 결과를 다른 worktree 로 redirect 못 함. `GIT_CEILING_DIRECTORIES` 는 policy-sensitive 라 의도적으로 preserve.

영향 없음: `/codex-review` 호출 인터페이스 변경 없음. 기존 scaffold 모드 사용자는 wrapper 가 자동으로 legacy `.claude/hooks/lib/` fallback 사용 (probe-based dual-layout resolver).

## v1.1.1 — 2026-05-12 (Plugin bootstrap gate hotfix)

v1.1.0 의 silent bootstrap failure (`trail/` 미생성 + 사용자 surface 누락) 를 hard gate 로 수정. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **첫 source 편집·Bash 호출 직전 차단 + 한 줄 명령 안내** — `trail/` 디렉토리가 없으면 PreToolUse(Edit|Write|MultiEdit) 또는 PreToolUse(Bash) gate 가 `exit 2` 로 차단하고 stderr 에 bootstrap 명령을 표시합니다. 사용자가 그 명령 한 번 실행 → `trail/` + `.rein/` 생성 → 다음 편집부터 정상.
- **`/reload-plugins` 후에도 동일 동작** — 새 세션 시작 경로와 `/reload-plugins` 경로 모두 같은 helper / 같은 메시지 / 같은 명령으로 수렴합니다. SessionStart hook 의 silent surface 한계를 PreToolUse hard gate 로 우회.
- **Non-git 프로젝트 지원** — `rein-bootstrap-project.py` 가 `git_root` 없을 때 `project_dir` 자체를 root 로 사용합니다. `git init` 절대 호출 안 함. 사용자가 git repo 가 아닌 폴더에서도 rein 활성화 가능.
- **UserPromptSubmit advisory** — 사용자가 첫 turn 에서 질문만 하더라도 `trail/` 부재를 알리는 advisory 가 매 user turn 마다 inject 됩니다 (편집 안 하는 turn 도 cover).
- **Opt-out 2-layer × 2-format** — `.rein/policy/hooks.yaml` 의 `bootstrap-gate: false` (umbrella, 두 gate 모두 off) 또는 individual key `pre-edit-trail-bootstrap-gate` / `pre-tool-use-bash-bootstrap-gate` (각각 bool 또는 `{enabled: false}` mapping) 로 비활성. 우선순위: individual > umbrella > default enabled.
- **Helper 메시지에 surface instruction 포함** — 안내 텍스트 끝에 `(Claude: surface this message to the user immediately before doing anything else.)` 명시. 모델 surface 확률 강화 (단 hard guarantee 는 PreToolUse 차단 자체).

Internal: `plugins/rein-core/hooks/lib/bootstrap-check.sh` helper (exit 0/10/11 + 5 unsafe categories + read-only git contract + authoritative write-attempt). 두 신규 차단 hook 가 Edit/Write/MultiEdit + Bash matcher group 의 첫 번째 hook 으로 배치 (`trail-rotate.sh` / `pre-bash-guard.sh` 보다 앞). `session-start-bootstrap.sh` 가 helper source 로 refactor 되어 메시지 owner 통일.

[v1.1.0 release notes](#v110--2026-05-12-plugin-prompt-level-operating-model).

## v1.1.0 — 2026-05-12 (Plugin prompt-level operating model)

7개 user-facing rule 의 prompt-level 책임을 plugin 사용자에게 적시 전달하는 lifecycle 확장. `rein update` 후 사용자 세션에서 다음이 바뀝니다.

- **세션 시작 시 더 풍부한 rule body inject** — 기존 `code-style` / `security` / `testing` 3개에 더해, `answer-only-mode` / `subagent-review` / `background-jobs` / `design-plan-coverage` 4개가 plugin tarball 에 포함됩니다. 각 rule 의 첫 단락은 **행동 강령 (action mandate)** — ≤2KB 의 self-contained 결론으로, Claude Code 의 10,000 chars cap 안에 항상 inline 보장.
- **새 hook 3개 작동 시점**:
  - `UserPromptSubmit` (매 사용자 turn) → `answer-only-mode` rule body advisory
  - `PreToolUse(Bash)` (Bash 도구 선택 직후) → `background-jobs` rule body advisory — `pre-bash-guard.sh` 의 차단 동작은 그대로 유지, 별도 advisory-only hook 으로 분리
  - `PreToolUse(Agent)` (subagent 호출 직전) → `subagent-review` rule body advisory
- **PostToolUse 이벤트 inject** — `docs/specs/**`, `docs/plans/**`, `trail/dod/dod-*.md` write/edit 직후 `design-plan-coverage` rule body 가 자동 inject 됩니다.
- **Rule body 가 cap 초과해도 잘리지 않음** — rein 은 자체 truncate 하지 않고 Claude Code 의 overflow-file handoff (full body 를 임시 파일로 + path 전달) 에 위임합니다.
- **broken reference 5건 해소** — `pre-edit-dod-gate.sh` / `post-write-dod-routing-check.sh` 의 stderr 메시지에서 사용자 repo 에 없는 `orchestrator.md` / `.claude/CLAUDE.md` 참조 제거. 대신 inline 절차 안내 ("DoD 에 '## 라우팅 추천' 섹션을 추가하세요…").
- **plugin rule 위치 정리** — `plugins/rein-core/skills/rules-prompt/` → `plugins/rein-core/rules/` 로 이동. skill 폴더 안 rule body 라는 어색한 layout 해소. `session-start-rules.sh` 의 `RULES_DIR` 함께 갱신.
- **post-edit dispatcher 출력 단일화** — 7 sub-hook 의 stdout 을 단일 JSON envelope 로 통합 (구분자 `\n\n---\n\n`). 기존 stderr 메시지는 그대로 통과. sub-hook 중 어느 하나라도 `exit 2` 면 dispatcher 도 `exit 2` 로 차단 (rein 의 hard-block 의미 보존).
- **publish-time 형식 검사** — `scripts/rein-publish.sh` 가 tarball build 전 `scripts/rein-validate-plugin-rules.py` 를 실행. `## 행동 강령` 절 존재 + ≤2KB + 모든 unconditional inject hook 이 valid PostToolUse/PreToolUse/UserPromptSubmit/SessionStart envelope 을 emit + `hooks.json` 의 모든 command target 이 실재 + executable 인지 검증.

Internal: `plugins/rein-core/hooks/lib/rule-inject.sh` helper (override probe + byte-exact passthrough + size diagnostic), `plugins/rein-core/hooks/lib/aggregator.sh` (NUL-framed concat helper), `tests/hooks/run-all.sh` 에 v1.1.0 신규 16 테스트 등록. `plugins/rein-core/docs/overflow-handoff.md` 신설로 cap 초과 시 동작 원리 문서화.

[v1.0.4 release notes](#v104--2026-05-11-domain-plugin-decommission--tarball-cleanup).

## v1.0.4 — 2026-05-11 (Domain plugin decommission + tarball cleanup)

- **`.claude/rules/legacy-shipped-pending.md` 가 public release tarball 에서 사라집니다** — v1.0.3 의 Q9 fix 후속. 메인테이너 회복 정책 문서로 dev-only 분류되었습니다. 사용자 hook 동작에는 영향 없음 (실 동작은 `scripts/rein-heal-legacy-pending.py` 가 처리).

Internal: 도메인 plugin 패키지 3개 (`plugins/rein-stitch`, `plugins/rein-react`, `plugins/rein-remotion`) + 8개 도메인 skill (`stitch-design`, `stitch-loop`, `taste-design`, `design-md`, `enhance-prompt`, `react-components`, `remotion`, `shadcn-ui`) 모두 폐기. marketplace.json 의 `plugins[]` 에는 처음부터 `rein-core` 만 등록되어 있어 사용자 install 경로가 부재했고, 통합 계획이 취소됐습니다. 의존 `tests/scripts/test-domain-plugins-bundle.sh` + drift checker 의 `DOMAIN_SKILL_DIRS` 화이트리스트 + branch-strategy 11 줄 함께 정리.

[v1.0.3 release notes](#v103--2026-05-11-mirror-tag-hygiene--reinsh-cleanup).

## v1.0.3 — 2026-05-11 (Mirror tag hygiene + rein.sh cleanup)

- **Public release tarball hygiene** — mirror workflow 가 release tag 도 strip 적용된 tree 로 force retag 한 뒤 push합니다. 신규 release (v1.0.3+) 부터 GitHub release `Source code (zip/tar.gz)` 안에 maintainer-only workflow (`daily-trail-audit.yml`, `repo-audit.yml`, `weekly-agent-evolution.yml`) + dev-only rule (`legacy-shipped-pending.md`) 가 포함되지 않습니다. 기존 v1.0.0~v1.0.2 tag 는 그대로 두며, 재게시 (retag) 는 별도 결정 사항.
- **`rein update` 메시지 미세 정정** — `claude plugin update rein-core` → `rein` (plugin manifest 의 `name` 과 정합).

Internal: `scripts/rein.sh` 의 약 1,335 줄 dead code 제거 — v1.0.0/v1.0.1/v1.0.2 거치며 `cmd_init`/`cmd_merge`/`cmd_update`/`cmd_remove` 가 단순화 또는 제거되며 caller 0 가 된 helper 약 30 개 + 7 dead globals + `rein_manifest_helper`/`rein_path_match_helper` 두 dead resolver (v1.0.2 에서 가리키는 Python 파일 삭제됨) 정리. 의존하던 stale 테스트 3 개 (`test-state-helpers.sh` / `test-gitignore-entries.sh` / `test-is-text-file.sh`) 삭제.

[v1.0.2 release notes](#v102--2026-05-11-claude-performance-hooks).

## v1.0.2 — 2026-05-11 (Claude performance hooks)

세션 시작/편집 hook 의 응답성을 개선하는 patch.

- **SessionStart 헤더 압축 + skill/MCP scan cache** — `trail/index.md` + skill 인벤토리 주입 시 cache 활용으로 lean SessionStart 응답속도 단축.
- **post-edit dispatcher 통합** — 7개 post-edit hook 을 단일 `post-edit-dispatcher.sh` 로 묶어 sub-hook fan-out 비용 절감 (Read tool 트리거에서는 post-edit hook 자체 skip).
- **policy profile (`lean` / `standard` / `strict`)** — `.rein/policy/hooks.yaml` 의 `profile:` 키로 hook 활성 범위 토글. lean = 단순 탐색/문서 작업용 (plan-coverage/spec-review-gate/dod-routing-check off).
- **trail-rotate early skip** — 하루 1회 실행 marker 가 fresh 하면 즉시 종료.
- **`rein-policy-loader.py` 신설** — profile + per-hook 토글 resolution 의 SSOT.

Internal: `scripts/rein-manifest-v2.py` + `scripts/rein-path-match.py` 제거 (v1.0.1 의 scaffold drop 으로 caller 0). `scripts/rein-bootstrap-project.py` 신설 (plugin-mode bootstrap 진입점).

[v1.0.1 release notes](#v101--2026-05-11-scaffold-drop-completion).

## v1.0.1 — 2026-05-11 (Scaffold drop completion)

v1.0.0 launch 의 declarative scaffold drop 을 코드 차원에서 완결합니다.

- `rein init` 명령 제거 — `init` / `init --mode=plugin` / `init --mode=scaffold` 모두 `unknown command 'init'` + exit 1 로 응답합니다. 설치는 Claude Code plugin marketplace 흐름만 사용합니다 (`/plugin marketplace add JayJihyunKim/rein` + `/plugin install rein@rein`).
- `rein migrate` 명령 제거 — v1.x scaffold → plugin 마이그레이션 helpers (`rein-migrate.sh` 등) 가 함께 사라집니다. v1.0.0 시점 사용자 베이스 0 가정 기반의 hard cut.
- repo root 의 `install.sh` 제거 — `curl|bash` 설치 흐름이 사라집니다. README / Windows troubleshooting 도 plugin marketplace 흐름으로 갱신.
- 사용자 repo 의 router state 디렉토리가 `.claude/router/` → `.rein/policy/router/` 로 이동합니다. `rein-route-record.py` 는 legacy `.claude/router/` 를 더 이상 fallback 으로 받지 않습니다 (hard-fail).
- README 의 "Claude scaffolds" 표현 + `.claude/settings.json` 자동 생성 안내 제거. plugin marketplace 흐름에 맞춰 KR/EN 동기화.

[v1.0.0 launch](#v100--2026-04-30-plugin-only-oss-launch) 의 deferred 항목을 단일 patch 로 ship 했습니다. user-facing 변경은 위 5 줄이며, 내부 정리 (migrate helpers / drift checker 어휘 / mirror strip 확장 / superseded 배너) 는 dev-only 라 본 entry 에 포함하지 않습니다.

## v1.0.0 — 2026-04-30 (Plugin-only OSS launch)

- 정식 OSS launch 의 첫 버전.
- Claude Code plugin 모드 (rein-core / rein-stitch / rein-react / rein-remotion) 가 유일한 install 경로. scaffold 모드 / `rein init --mode=scaffold` / `rein remove --path` 는 제거됨.
- 이전 dev cycle history (v0.x ~ v2.0.0) 는 [archive](docs/changelog-archive/2026-04-pre-v1.md) 를 참조.
