# DoD — SR-1.b orphan 백스톱 mtime 거짓양성 → 내용 기반 비교 전환

- 날짜: 2026-05-29
- 유형: fix
- 보안 tier: (security/profile.yaml 기준 — review 단계에서 확인)
- plan ref: N/A (백로그 SR-1.b-MTIME-FP, need-to-confirm.md 한눈 표 우선순위 2)

## 증상 / 재현

`pre-edit-dod-gate.sh` 의 orphan `.reviewed` 백스톱(현 489-521)이 spec 파일의 **파일시스템 mtime** 을 `reviewed=` 타임스탬프와 비교한다. mtime 은 내용이 아니라 파일 조작 시점을 반영하므로:

- `git checkout <branch>` 가 dev-only 문서(`docs/specs/**`, `docs/plans/**`)를 삭제→재생성하면 내용 변경 없이 mtime 이 "now" 로 갱신
- `git checkout dev -- <file>`, cherry-pick, rotation 도 동일하게 mtime 갱신
- → `spec_mtime > reviewed` → 거짓 "stale" → 무관한 소스 편집이 연쇄 차단

실제 발현: 2026-05-29 가드 작업 중 branch 조작으로 25개 무관 문서의 orphan `.reviewed` 가 동시에 stale 판정되어 매 편집마다 일괄 회고 갱신으로 우회해야 했음. 코드 주석(459-464)이 "R1 risk accepted" 로 미리 명시한 위험이 반복 발현됨.

## Root cause

mtime 은 내용 동일성의 신호가 아니다. "리뷰 이후 spec 내용이 바뀌었는가" 를 판정해야 하는데 mtime 은 파일시스템 touch 마다 갱신된다. SR-1 본 분기(438-447)는 rein 이 쓴 `created=`/`reviewed=` 이벤트 타임스탬프를 비교하므로 정확하지만, orphan 분기(SR-1.b)만 mtime proxy 를 쓴다.

## 수정 방향 (codex Mode B 검증 완료 — "강화 A안" 확정)

> codex Mode B (gpt-5.5/high, 2026-05-29, `/tmp/codex-ask-sr1b-2.out`) 결론: **content_sha 1순위 strict + 회고-도장 한정 git fallback**. codex 가 내 초안 Tier 2(광범위 commit-time)의 FN 을 지적: clean branch/detached HEAD 로 *다른 옛 내용* 체크아웃 시 commit_epoch ≤ reviewed 라 통과 → 미리뷰 내용에 소스편집 허용(FN). content_sha 만 이를 정확히 차단.

orphan 백스톱 staleness 판정 (per orphan `.reviewed`; spec 존재; reviewed= ISO 통과; 예외는 fail-closed=block):

1. **TIER 1 — `content_sha=` 앵커 (PRIMARY, strict)**: writer 가 review 시점 spec 내용 byte 해시(Python hashlib sha256)를 마커에 기록. gate 가 현재 내용 해시 재계산 비교. 동일 → not stale, 상이 → stale, 계산 실패 → fail-closed. checkout/cherry-pick/rotation/리뷰후-동일내용-커밋 면역 + 미커밋 편집 FN-safe.
2. **TIER 2 — 회고-도장 한정 git commit-time fallback** (`content_sha` 없는 기존 마커 중 `mechanism=rein-heal-legacy-pending` 또는 `reviewer` 가 `retrospective-shipped` 로 시작하는 것만): git work tree + spec tracked(`git ls-files --error-unmatch`) 확인 후 dirty(`git diff --quiet HEAD`)→stale, `git log -1 --format=%ct` commit_epoch>reviewed→stale, else not stale. 이번 25개 incident(대부분 retrospective-shipped healer 마커) 해소. blast 를 회고-도장으로 한정해 출처 불명 옛 마커는 무분별 통과 안 됨(codex 지적).
3. **TIER 3 — mtime fallback**: content_sha 없는 비-회고 마커, 또는 non-git. 현 mtime>reviewed→stale 동작 보존. 비-회고 마커는 다음 review 시 content_sha 획득해 TIER 1 로 migration.

codex 반영 세부:
- writer 는 hash 실패 시 **조용히 생략 금지** — mark 명령 실패(앵커 없는 도장 = 고치려던 약한 상태). PD-1 fail-closed 와 동일 철학.
- 내용 해시는 byte 단위 Python hashlib (`git hash-object` 아님 — .gitattributes clean 필터/저장소 의존 회피). path-hash `compute_hash`(shasum-of-path)와 별개 필드.
- tracked 판정은 `git ls-files --error-unmatch` (git log 이력 단독 신뢰 금지).
- 모든 git 호출 BC-INFO1 살균(`env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE`, `git -C "$PROJECT_DIR"`).
- SR-1 본 분기(`.pending` 존재 시) 불변 — orphan 분기만 수정.

## 잔존 한계 (의도적 수용)

- TIER 2 회고-도장 fallback 은 codex 표현으로 "security-equivalent 아닌 compatibility heuristic". clean 체크아웃으로 옛 내용 + 회고-도장 조합의 FN 이 이론상 남으나, 출하/회고 문서를 옛 커밋에서 편집하는 시나리오 자체가 비정상이라 low-risk 수용.
- 비-회고 content_sha-less 마커는 다음 review 까지 mtime FP 잔존(migration 대기).

## 변경 파일

- plugins/rein-core/hooks/pre-edit-dod-gate.sh — orphan 백스톱을 3단계 content-based 로 교체
- plugins/rein-core/scripts/rein-mark-spec-reviewed.sh — `content_sha=` 기록 (해시 실패 시 fail-close)
- scripts/rein-mark-spec-reviewed.sh — repo fallback 사본 동기화 (위와 byte-identical)
- plugins/rein-core/scripts/rein-heal-legacy-pending.py — `content_sha=` 기록 (best-effort, 실패 시 TIER 2 degrade)
- scripts/rein-heal-legacy-pending.py — repo fallback 사본 동기화 (위와 byte-identical)
- tests/hooks/test-spec-review-gate.sh — orphan 백스톱 8 + writer 2 신규 회귀 테스트

(그 외 diff 항목 trail/dod/.active-dod·.review-pending·meta-check jsonl·본 DoD 파일 등은 hook 이 생성하는 런타임 마커 — 소스 변경 아님)

## 회귀 방지 테스트 (신규 — orphan 백스톱은 현재 무테스트, git 세팅 명시)

TIER 1 (content_sha):
- MUST ALLOW: content_sha 일치 + mtime=now (checkout 재생성/mtime 무시) → 통과 (FP 회귀 방지 핵심)
- MUST BLOCK: content_sha 불일치(내용 변경) → 차단
- MUST BLOCK: content_sha 불일치 + 미커밋 변경 → 차단

TIER 2 (회고-도장 한정, git sandbox):
- MUST ALLOW: `reviewer=retrospective-shipped-*` 마커 + clean checkout(commit_epoch ≤ reviewed) → 통과 (25개 incident 해소)
- MUST BLOCK: 회고-도장 + dirty tracked path → 차단
- MUST BLOCK: 회고-도장 + commit_epoch > reviewed → 차단
- MUST BLOCK: 회고-도장 + untracked(`ls-files --error-unmatch` 실패) → fail-closed

TIER 3 / 보존:
- non-회고 content_sha-less orphan → mtime 동작 유지 (현 거동)
- non-git sandbox orphan → mtime 동작 유지
- `.pending` 동반 시 SR-1 본 분기(불변) 경유 — 기존 6 테스트 GREEN 유지
- writer: hash 실패(예: spec 부재) 시 mark 명령 exit≠0 (fail-closed, 조용한 생략 금지)

## 비목표

- SR-1 본 분기(`.pending` vs `.reviewed`) 로직 변경
- 적대적으로 조작된 마커 내용 방어(기존 fail-closed 수준 유지)

## 라우팅 추천
```yaml
agent: direct-main-session
skills: [codex-review]
mcps: []
rationale: 근본원인 조사 + 코드 정독 + codex Mode B 설계검증이 모두 이 세션 맥락에 누적 — 하위 에이전트 위임 시 맥락 손실. 단일 hook boundary 로직 + writer 2곳 동기화의 집중 수정이라 세션 직접 reproduction-first TDD 가 효율적. 완료 후 codex-review(Mode A, 한도 복귀) + security-reviewer.
approved_by_user: true
```
