# DoD — GE-1 + GE-2 wrapper/selector 무결성 묶음

- 날짜: 2026-05-22
- 유형: fix (security hardening — path containment + stamp diff_base ancestor 검증)
- plan ref: docs/specs/2026-04-26-wrapper-context-lifecycle-hardening-design.md §Non-functional Requirements + OQ-9/OQ-11 (본 사이클이 명시적으로 deferred 한 "별 hardening 후속" — need-to-confirm GE-1/GE-2)

## 목표 (Why)

2026-04-26 wrapper-context-lifecycle hardening 사이클이 **의도적으로 deferred** 한 2개 잔존 risk 를 닫는다 (design §231/§240/OQ-9/OQ-11, Round 6/7 에서 "별 사이클 후속, need-to-confirm 등록 권장" 으로 명시):

- **GE-1**: `select-active-dod.sh` Tier 1 marker `path=` 채택 시 path containment 검증 부재 (`[ -f ]` 존재만). 오염된 `.active-dod` 가 프로젝트 외부 경로(절대경로/`..`/메타문자)를 가리키면 Tier 1 blocking authority 로 그대로 채택. session-start cleanup 이후 새로 오염된 marker 가 selector 에 도달하는 경로가 본 사이클 보증 외였음.
- **GE-2**: `rein-codex-review.sh::_resolve_diff_base` 가 fresh stamp 의 `diff_base:` SHA 를 유효성 검증 없이 채택. orphan commit / other-branch / forged SHA 가 그대로 envelope diff_base 로 주입됨.

## 성공 기준 (Acceptance)

1. **공용 helper** — `plugins/rein-core/hooks/lib/path-containment.sh` 신설. `validate_repo_relative_path <project_dir> <path>` = 0 iff path 가 (1) 비어있지 않고 (2) `^[a-zA-Z0-9_./-]+$` allowlist 충족 (3) `..` segment 없음 (4) realpath 후 project_dir commonpath 일치. 위반 시 non-zero + 표준 reason 토큰을 stdout 으로 방출. 멱등 source guard.
2. **GE-1 selector** — `select-active-dod.sh` Tier 1 분기가 `[ -f ]` 검사 **전에** helper 호출. 위반 시 Tier 1 거부 + `_sad_log_invalid_marker` 로 reason 기록 + Tier 2 fallback. (CWD = PROJECT_DIR 가정은 기존 caller 계약과 동일.)
3. **GE-1 session-start 리팩토링** — `session-start-load-trail.sh` 의 inline 4-check (empty/metachar/`..`/commonpath, 현 line 95-107) 를 helper 호출로 교체. **기존 incident-log REMOVE_REASON 의미 보존** (기존 `test-session-start-marker-cleanup.sh` 4케이스 무회귀). archived/range-link 검사(b/c/d)는 불변.
4. **GE-2 ancestor 검증** — `_resolve_diff_base` fresh stamp 분기에서 stored `diff_base` 채택 전 `git rev-parse --verify "<sha>^{commit}"` (object 존재·commit 타입) AND `git merge-base --is-ancestor <sha> HEAD` (HEAD 도달 ancestor) 검증. 둘 중 하나라도 실패 → stamp 무시 + HEAD~1 fallback (OQ-3 fail-safe 동일 경로, `return 0` 안 함).
5. **회귀 테스트 (TDD, 실패 → 통과)**:
   - helper 단위: 유효 상대경로 통과 / 절대경로 / `..` traversal / 메타문자(`;`) / commonpath escape(symlink) 거부.
   - GE-1 selector: 외부 경로 marker → Tier 1 거부(Tier 2 또는 0 로 fallback) + incident 기록. 정상 marker → Tier 1 유지(무회귀).
   - GE-2: (a) orphan SHA (b) other-branch SHA (c) non-existent SHA 가 fresh stamp 의 diff_base 일 때 → HEAD~1 fallback. (d) valid ancestor SHA → 채택(Test 1 갱신: 기존 fabricated `deadbeef…` → real HEAD~1 SHA).
6. **무회귀** — `test-select-active-dod.sh`, `test-session-start-marker-cleanup.sh`, `test-codex-review-stale-stamp.sh`, `test-codex-review-wrapper.sh` 전량 PASS.
7. codex 리뷰 PASS + `.codex-reviewed` stamp, security 리뷰 PASS + `.security-reviewed` stamp.

## 제외 (Out of scope)

- 다른 need-to-confirm 항목 (G8-3/SR-1.b/G3/BC-INFO1/A-LowPrio).
- stamp schema 변경 (7 필드 불변 — design §232). diff_base **값 검증**만 추가, 필드 추가 없음.
- selector Tier 2 fallback 로직 자체 변경 (mtime/tie-break 불변).
- pre-edit-dod-gate 의 selector caller 분기 로직 (출력 contract 불변 — design §231).

## 리스크

- (R1) session-start 리팩토링 회귀. → 기존 `test-session-start-marker-cleanup.sh` 4케이스(a `..`/b 절대경로/c 메타문자/d symlink)가 helper 경유 후에도 동일 삭제+reason 보장. helper 가 기존과 동일 4-check 수행.
- (R2) GE-2 가 정상 fresh stamp 까지 reject (false-positive). → real ancestor SHA 는 rev-parse+merge-base 둘 다 통과. Test 1 을 real HEAD~1 SHA 로 갱신해 정상 경로 보존 확인. HEAD 부재(pre-commit) 시 fresh 분기 자체 미진입(head_iso 빈값 guard).
- (R3) helper 의 project_dir 의미 불일치. → session-start 는 `$PROJECT_DIR` + repo-relative path, selector 는 CWD(=PROJECT_DIR) 기준. helper 가 `realpath(join(project,target))` 로 절대/상대 모두 처리(Python os.path.join 절대경로 흡수). selector 는 `$PWD` 전달.
- (R4) empty-tree SHA(`4b825…`)가 stamp diff_base 일 때 `^{commit}` 실패 → HEAD~1 fallback. 정상(empty-tree 는 commit 아닌 tree, fallback 이 더 안전).

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix    # GE-1/GE-2 = security hardening bugfix. reproduction-first TDD
skills:
  - rein:codex-review              # commit gate 필수 (.codex-reviewed)
mcps: []
rationale: >
  design 문서가 명시적으로 deferred 한 2개 잔존 risk(GE-1 selector path containment,
  GE-2 stamp diff_base ancestor)를 닫는 hardening 묶음. reproduction-first TDD 로 우회
  시나리오(외부경로 marker / forged SHA)를 failing test 로 고정 후 수정. 본 세션이 이미
  selector/session-start/wrapper/양쪽 테스트/design 문서를 전부 read 해 컨텍스트 완전 →
  메인 세션 직접 구현. security_tier=full — path traversal + diff_base 신뢰성은 보안 표면.
security_tier: full                # path containment + ancestor 검증 = 보안 표면
approved_by_user: true             # 사용자 승인 (2026-05-22 "공용 함수 공유" + "지금 세션 직접" 선택)
```

## Self-review 예정 항목 (AGENTS.md §6)

- helper 가 session-start 의 4-check 와 동일 의미를 보존하는가 (회귀 0)
- selector Tier 1 거부 시 Tier 2 fallback + incident 기록이 정상인가
- GE-2 가 정상 fresh stamp(real ancestor)를 reject 하지 않는가 (false-positive 없음)
- GE-2 fail-safe 가 OQ-3 와 동일 HEAD~1 경로로 수렴하는가
- design §제외(stamp schema 불변, selector 출력 contract 불변) 준수했는가
