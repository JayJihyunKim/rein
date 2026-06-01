---
name: parallel-execute
description: 활성 plan 의 `## 실행 전략`(depends_on/mode/scope v2) 을 읽어 의존 위상정렬로 웨이브를 유도하고, 각 웨이브의 독립 edit_only 태스크를 같은 작업 트리에서 서브에이전트로 병렬 실행, mutating·의존 태스크는 순차 실행한다. 부모(메인 세션)가 웨이브 단위로 검증·테스트·커밋. 호스트가 병렬 dispatch 불가 시 순차 fallback 으로 degrade.
---

# parallel-execute

스키마 상세: `plugins/rein-core/docs/exec-strategy-schema.md`(v2). 이 스킬은 그 스키마를 **소비**한다.

## 목적

검증 통과한 plan 의 `## 실행 전략` v2(`tasks[]`+`depends_on`+`mode`+`scope`)를 위상정렬로 웨이브로 나눠, 같은 작업 트리에서 독립 edit_only 태스크를 병렬 서브에이전트로 실행, mutating·의존 태스크는 순차 실행. 부모가 웨이브 경계마다 검증·테스트·커밋. 격리는 강제 sandbox 가 아니라 워커 규율 + 부모 사후 델타 검증 두 겹.

## 사용 시점

활성 plan 의 `## 실행 전략` 이 v2 `tasks[]` 일 때만 **명시 호출**(자동 발동 없음). 부재 / 단일 태스크 / 구 `parallelizable` shape 는 대상 아님.

## Preflight

1. plan 의 `## 실행 전략` 을 파싱. validator(`rein-validate-coverage-matrix.py`)가 위상정렬·사이클·disjoint·legacy 를 이미 fail-closed 검증함을 **전제**(재검증 안 함).
2. 섹션 **부재** → 병렬 대상 아님. 순차 실행 안내 후 종료.
3. 구 `parallelizable:`/`workers:` shape → validator exit 2 차단. 마이그레이션 안내 후 종료.

## 웨이브 유도 + 결정적 스케줄러

웨이브 = 위상정렬로 묶인 동시 실행 단위. 매 스텝 규칙:

- **ready 집합** = `depends_on` 가 모두 완료된 미실행 태스크.
- ready 에 `mutating` 있으면 → **plan 순서 가장 앞선 mutating 1개만 단독** 실행 후 ready 재계산.
- ready 가 전부 `edit_only` → 전부를 **한 메시지에서 병렬 dispatch**(Agent 도구 다중 호출).
- `mutating` 은 어떤 태스크와도 동시 실행 금지. 사이클 없음(검증기 보증) → 데드락 없음.

**canonical 순서 SSOT** — 부모는 결정성을 재정의하지 않고 Phase 1 emitter 를 소비한다:

```
python3 scripts/rein-validate-coverage-matrix.py schedule <plan>
```

출력은 웨이브당 한 줄 `step <n>: <id> [<id> ...]`(id 는 plan 순서). 부재 → 빈 출력+exit 0, 무효/legacy → exit 2. 각 `step` 을 한 웨이브로 dispatch(1개=단독, 여럿=병렬). emitter 미가용 시 위 규칙 복제.

## 워커 dispatch 계약

워커 = 한 태스크를 같은 작업 트리에서 실행하는 서브에이전트. dispatch 시 `task_id`·`mode`·`scope`·금지목록을 프롬프트로 전달. 워커는 **마커/결과 파일 없이** 결과를 최종 메시지로 반환.

**공통 결과 스키마**(두 변형 동일): `task_id`(필수) / `status: completed|blocked`(필수) / `changed_files: [repo-relative path...]`(필수, advisory) / `blocked_reason`(blocked 시 필수) / `recommendation: parent_fallback|split|scope_expand`(blocked 시) / `summary`(1-3줄). 부모는 `status=blocked` 또는 **결과 누락(timeout/truncation)** 을 **미완** 처리 → 의존 후속 진입 불가, `recommendation` 으로 분기.

**edit_only 변형**: 선언 `scope` 파일만 편집(best-effort). **금지** — 커밋 금지·스테이징·리뷰/보안 stamp 금지·trail 기록·전체 포매터·변경성 테스트/코드젠. 같은 웨이브 여러 edit_only 는 한 메시지 병렬 dispatch.

**mutating 변형**: 자기만의 **단독 웨이브**(서브에이전트 1개) dispatch. edit_only 금지목록 중 **변경성 명령 허용**(코드젠·변경성 테스트·설치). 단 커밋·스테이징·stamp·trail 은 부모 소유 금지. 공통 결과 스키마 **동일** 반환. 부모 검증 `scope` = 선언 + **예상 부작용 경로**(plan-writer 가 함께 선언). mutating 도 "선언(+부작용) 밖 변경 = reject".

## 호스트 능력 fallback

호스트가 병렬 dispatch 불가하면 **순차 fallback**: 같은 emitter 순서로 각 태스크를 plan 순서로 순차 실행. 검증·커밋 경로(부모 통합)는 병렬과 **동일**.

## 부모 통합 (barrier)

부모(메인 세션)가 웨이브 경계마다 barrier 로 통합:

1. **클린 시작** — 각 웨이브는 **클린 트리**에서 시작(직전 웨이브 커밋이 보장, 첫 웨이브는 세션 현재 커밋 상태). 경계 dirty → **중단·보고**(무관 변경 혼입 방지).
2. **시작 이후 델타** 산출(기계가독): `git status --porcelain=v1 -z -uall --ignored=no` (fallback: `git diff --name-only HEAD` + `git ls-files --others --exclude-standard` — `-z` 아니므로 4번 정규화 상속) → **repo-relative literal 파일 경로** 정규화(`-uall` 로 untracked 디렉토리 collapse 방지).
3. **부분집합 검증** — 델타 ⊆ 그 웨이브 `scope`(mutating 은 +예상 부작용 경로) 합집합. per-worker 귀속 불가 → 워커 `changed_files` 는 advisory.
4. **scope 경로 안전화(보안, 필수)** — `scope`·델타 경로를 검증 전 정규화: **절대경로·`..`·`..\`·NUL·드라이브문자(`C:`) 포함 시 reject** (path traversal 차단), 나머지는 `realpath`(symlink resolve) 후 프로젝트 루트 prefix **containment** 검증(밖이면 reject). 정규화 실패 경로는 합집합에서 제외. **scope·델타 양쪽을 동일 정규형으로** 비교(검증기 미필터 — 이 단계가 유일 방어선).
5. 선언 밖 변경 → **reject + 보고**(커밋 안 함). 통과 → 웨이브 단위 1회 포맷/린트/테스트/리뷰 → 그 델타만 **웨이브당 1커밋** → 다음(다시 클린 시작).

## 사용자 보고 방식

내부 식별자(델타·부분집합·stamp)를 평문 번역: 시작="N번째 묶음(K개)을 병렬 실행", 완료="변경 확인·검증·테스트 후 한 번에 커밋", 차단="선언 파일 밖을 건드려 멈춤, 커밋 안 함".
