---
name: code-reviewer
description: /rein:codex-review 장애 시 fallback 리뷰어. 변경된 코드에 대해 AGENTS.md rules + 체크리스트 기반으로 리뷰하고 PASS 시 v2 증거를 발급한다.
triggers:
  - /codex-review 호출 타임아웃
  - /codex-review 호출 에러(exit non-zero)
  - superpowers:code-reviewer 미설치 + codex 자체 불가 환경
---

# code-reviewer (rein-native fallback)

## 실행 조건

이 스킬은 `/codex-review` 리뷰 게이트를 대체하지 않는다. AGENTS.md §5-1 / `.claude/skills/codex-review/SKILL.md` 의 규정은 "codex 실패 시에만 fallback" 이며, 본 스킬은 그 fallback 경로의 rein-native 구현이다. 사용자의 임의 요청만으로는 호출하지 않는다.

1. **codex_timeout** — `/codex-review` 호출이 타임아웃
2. **codex_error** — `/codex-review` 가 exit non-zero 로 실패
3. **no_superpowers_plugin** — `superpowers:code-reviewer` 플러그인이 없고 `/codex-review` 경로도 사용 불가

아래 "리뷰 결과 기록" 섹션에서 위 slug (codex_timeout / codex_error / no_superpowers_plugin) 중 어느 사유로 호출됐는지를 사람 보고 문구에 그대로 참조한다 (Phase 7 웨이브 3 ③-d 이후 v2 발급은 verdict/digest 만 받으므로, 이 slug 는 기록 필드가 아니라 사람 안내용이다).

## v2 evidence subject 스냅샷 캡처 (리뷰 시작 전)

아래 체크리스트 리뷰를 시작하기 **전에**, 리뷰 대상 상태의 digest 와 그 digest 가 실제로 흡수하는 인증된 경로 목록을 **한 번의 호출로 함께** 캡처해 둔다(Phase 7 웨이브 3 ③-a code review round 3 — 이전에는 경로 목록을 리뷰가 끝난 뒤 `files_reviewed` 통계 집계용으로만 별도로 다시 조회했다. 그러면 인증된 경로가 애초에 리뷰 대상 결정에 쓰이지 못하고, 리뷰 시작 시점 캡처와 별개 시점 조회 사이에 트리가 바뀌면 두 값이 서로 다른 상태를 증명할 위험도 있었다). digest 는 리뷰 완료 후 "v2 evidence 발급 시도" 절에 그대로 쓰인다(Phase 7 웨이브 3 ③-d 이후 발급 호출이 유일한 기록 경로 — stamp 파일은 더 이상 없다) — 리뷰가 실제로 검토한 상태와 발급 시점 상태가 같은지 v2 가 검증할 수 있게 하기 위함이다.

**NUL-safe consumption (Phase 7 wave 3 ③-a code review round 4, High-1)** — git allows newline-containing filenames, and `--print-subject` returns them RAW. The earlier version of this snippet printed one path per line (`for p in paths: print(p)`) and let bash split on newline — a single path like `dir/line\nbreak.py` became TWO entries once bash re-split it, silently corrupting `$REIN_CERTIFIED_PATHS`'s membership. All structural work now happens inside the one python process; only the digest (a scalar, never contains a newline) crosses back via stdout — the path list is written directly to a NUL-delimited temp file, and bash reads it back only with `while IFS= read -r -d ''` (never newline-splitting a path). Each entry then gets its embedded newlines (if any) escaped to a literal `\n` (two-char backslash-n) before it joins the newline-per-entry `$REIN_CERTIFIED_PATHS` display variable below — that keeps "one line = one path" true for the checklist review's reading of it, no matter what the raw filename contains:

~~~bash
REIN_SUBJECT_JSON=$("${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/bin/rein" issue-evidence code_review --print-subject 2>/dev/null || true)
REIN_PATHS_FILE=$(mktemp "${TMPDIR:-/tmp}/rein-cr-subject-paths.XXXXXX" 2>/dev/null || true)
REIN_REVIEWED_DIGEST=""
if [ -n "$REIN_PATHS_FILE" ]; then
  REIN_REVIEWED_DIGEST=$(printf '%s' "$REIN_SUBJECT_JSON" \
    | REIN_PATHS_OUT="$REIN_PATHS_FILE" python3 -c '
import json
import os
import sys

try:
    data = json.load(sys.stdin)
    subject = data.get("subject", "")
    paths = data.get("paths", [])
    if not isinstance(paths, list):
        paths = []
except Exception:
    sys.exit(1)

out_file = os.environ.get("REIN_PATHS_OUT", "")
if out_file:
    with open(out_file, "wb") as fh:
        for p in paths:
            fh.write(str(p).encode("utf-8", "surrogateescape"))
            fh.write(b"\0")

sys.stdout.write(subject)
' 2>/dev/null || true)
fi
REIN_CERTIFIED_PATHS=""
if [ -n "$REIN_PATHS_FILE" ] && [ -s "$REIN_PATHS_FILE" ]; then
  _rein_cert_lines=()
  while IFS= read -r -d '' _rein_cert_p; do
    # Injective escape — backslash FIRST, then LF (JSON-string-style
    # order). Escaping LF before backslash would let a real LF and a
    # literal `\n` (backslash-n) in a filename collapse to the same
    # rendered form, merging two distinct certified paths under a later
    # dedup. Escaping backslash first means the literal `\n` case ends up
    # as `\\n` (backslash backslash n) while the real-LF case ends up as
    # `\n` (single backslash n) — always distinguishable.
    _rein_cert_p="${_rein_cert_p//\\/\\\\}"
    _rein_cert_lines+=("${_rein_cert_p//$'\n'/\\n}")
  done < "$REIN_PATHS_FILE"
  if [ "${#_rein_cert_lines[@]}" -gt 0 ]; then
    REIN_CERTIFIED_PATHS=$(printf '%s\n' "${_rein_cert_lines[@]}")
  fi
fi
[ -n "$REIN_PATHS_FILE" ] && rm -f "$REIN_PATHS_FILE"
~~~

**`$REIN_CERTIFIED_PATHS` 를 아래 체크리스트 리뷰의 대상 하한으로 삼는다** — 이 목록의 파일 각각을 리뷰 대상에 반드시 포함해야 한다(단순히 "무엇이 바뀐 것 같다"는 추측이 아니라, `--print-subject` 가 실제로 review digest 로 증명하는 정확한 집합이다). 저장소 맥락상 필요한 다른 파일을 더 읽는 것은 자유지만, 이 목록의 항목을 빠뜨리면 발급 시 "증명한 파일 ≠ 실제로 리뷰한 파일" 이 된다.

캡처가 실패해도(digest·paths 둘 다 빈 값) 리뷰 자체는 막지 않는다 — 체크리스트 리뷰는 그대로 진행한다. 다만 아래 "리뷰 결과 기록" 절의 v2 발급은 이 digest 없이는 시도조차 할 수 없고(발급이 빈 값을 받으면 스스로 스킵한다), legacy stamp 같은 대체 기록 경로는 더 이상 존재하지 않는다(Phase 7 웨이브 3 ③-d — `.codex-reviewed`/`.review-pending`/`.security-reviewed` 3종의 write·read 경로 전체 제거). 즉 **캡처 실패 = 이번 회차에 기록 가능한 통과 증거가 없다**는 뜻이다. 리뷰 결론이 PASS 라도 이 경우엔 "리뷰는 수행했으나 이번 회차는 기록되지 않았다 — git 상태를 다시 확인한 뒤 재실행이 필요하다"를 사용자/부모에게 명시적으로 보고한다 (아래 "사용자 안내" 절 참조).

## 리뷰 체크리스트

리뷰 시작 전 아래 규칙 파일을 먼저 로드하여 각 그룹의 기준을 확인한다.

### 1. 보안 (`plugins/rein-core/rules/security.md` 기준)

- [ ] 하드코딩된 credential (API 키, 비밀번호, 토큰) 없음
- [ ] 모든 외부 입력(사용자 입력, 환경 인수, 파일 경로)에 검증 로직 존재
- [ ] SQL / 쉘 / HTML 주입 공격 방어 처리 확인
- [ ] `.env` 파일 또는 `secrets/` 디렉토리 직접 접근·커밋 없음

### 2. 코드 스타일 (`plugins/rein-core/rules/code-style.md` 기준)

- [ ] 네이밍: 함수 동사형 camelCase, 상수 UPPER_SNAKE_CASE, Boolean `is/has/can/should` 접두사
- [ ] 함수 길이 50줄 이내 (초과 시 분리 권고)
- [ ] 파라미터 3개 이하 (초과 시 객체 묶음 권고)
- [ ] 중첩 depth 3단계 이하 (early return 또는 함수 분리)
- [ ] `any` 타입(TypeScript) / `console.log`·`print` 운영 코드 방치 없음
- [ ] 주석: diff 에서 **추가되거나 수정된(added/modified) 주석 줄만** 검사 — 회차 서수·수리 이력 서사·실행 결과 측정 수치가 새로 들어왔으면 삭제 또는 trail 이동을 요구하고, 해당 diff 목적과 무관한 기존 주석 전체의 일괄 청소는 요구하지 않는다

### 3. 테스트 (`plugins/rein-core/rules/testing.md` 기준)

- [ ] 변경 범위에 해당하는 테스트가 추가 또는 수정됨
- [ ] 경계 조건(null/undefined, 빈 값, 최대/최소값) 커버
- [ ] 외부 API 직접 호출 단위 테스트 없음 (Mock 사용 확인)
- [ ] 모킹 과다 여부 — 실제 동작보다 mock 구조 검증에 편중되지 않음

### 4. Rein 고유

- [ ] `trail/dod/dod-YYYY-MM-DD-<slug>.md` 파일이 이 작업 전 생성되어 있음
- [ ] DoD 또는 plan work unit 에 `covers: [...]` 메타데이터가 존재하고 매트릭스 ID 와 일치
- [ ] 작업 완료 후 `trail/inbox/YYYY-MM-DD-작업명.md` 기록 대상임을 확인

## 출력 형식

리뷰 결과를 아래 마크다운 템플릿으로 출력한다:

~~~markdown
## 코드 리뷰 결과 (rein-native, round N)

**리뷰 대상**: [파일 목록]
**라운드**: N

### High (즉시 수정 필요)

- [파일:줄번호] 이슈 설명 — 권고 조치

### Medium (수정 권고)

- [파일:줄번호] 이슈 설명 — 권고 조치

### Low (선택 개선)

- [파일:줄번호] 이슈 설명

### 통과 항목

- 보안: 하드코딩 credential 없음
- 스타일: 네이밍 규칙 준수
- 테스트: 변경 범위 커버됨
- Rein 고유: DoD 파일 존재 확인

**결론** (아래 중 하나):
- 통과 — 이슈 없음, 본 스킬이 v2 발급으로 기록
- 재리뷰 (self-review) — Low 만 또는 Medium ≤3줄, 수정 후 sonnet self-review 로 v2 발급 기록
- 재리뷰 (same reviewer) — Medium >3줄 또는 High 1건 이상, 수정 후 본 스킬 재실행
- 에스컬레이션 — 3라운드 후에도 High 잔존, 사람에게 직접 보고 (기록 없음)
~~~

## 리뷰 에스컬레이션 흐름

AGENTS.md §5-1 / `.claude/skills/codex-review/SKILL.md` 의 표와 일치한다.

| 라운드 결과 | 규모 | 다음 행동 |
|-----------|------|----------|
| 이슈 없음 | — | **통과** (본 스킬이 v2 발급으로 기록) |
| Low 만 | — | 수정 후 **sonnet self-review, v2 발급으로 기록** |
| Medium 만 | ≤3줄 | 수정 후 **sonnet self-review, v2 발급으로 기록** |
| Medium 만 | >3줄 | 수정 후 본 스킬 재실행 (round N+1) |
| High 1건 이상 | — | 수정 후 본 스킬 재실행 (round N+1) |
| 3라운드 이후 High 잔존 | — | **에스컬레이션** (기록 없음 — 사람에게 직접 보고) |

## 리뷰 결과 기록 (v2 발급 — 유일한 기록 경로)

**Phase 7 웨이브 3 ③-d 갱신.** 이전에는 이 스킬이 legacy stamp (`trail/dod/.codex-reviewed` 파일 생성 + `trail/dod/.review-pending` 삭제) 를 먼저 기록하고, 그 위에 v2 발급을 "병행 기록"으로 시도했다. ③-d 로 legacy 리뷰 표식 3종(`.review-pending`/`.codex-reviewed`/`.security-reviewed`)의 write·read 경로가 전부 제거되면서, 이제 **v2 발급 호출 자체가 유일한 기록 절차**다 — 별도의 stamp 파일을 먼저 쓰는 단계는 없다. `<REASON>` 은 "실행 조건" 섹션의 slug (codex_timeout / codex_error / no_superpowers_plugin) 중 하나이며, 아래 사용자 안내 문구에서 참조용으로만 쓰인다 (기록되는 필드가 아니다 — v2 발급이 받는 인자는 verdict 와 reviewed-digest 뿐이다).

### Spec-review fallback 분기 (CRITICAL, v1.0.0+)

이 스킬이 **`[NON_INTERACTIVE] spec review for plan:` 또는 `design:` prefix 가 붙은 prompt** 로 호출된 경우 (plan-writer 의 codex 실패 fallback 경로), 아래 "PASS 시 v2 발급" 절차를 **실행하지 않는다** — code-review 기록 절차 자체가 이 경로에 존재하지 않는다.

근거: code-review v2 발급은 코드리뷰 게이트 증거다. spec review fallback 에서 이 증거를 발급하면 코드 변경 없이도 gate 통과 가능 → rein 규율 오염.

Spec-review fallback 동작:
1. 리뷰 수행 (AGENTS.md rules + 체크리스트) — 내용 자체는 동일
2. verdict 만 caller (plan-writer) 에게 반환 — PASS / NEEDS-FIX / REJECT
3. **code-review v2 발급 없음**. legacy marker 도 이제 존재하지 않으므로 건드릴 대상 자체가 없음
4. caller 가 PASS 시 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/scripts/rein-mark-spec-reviewed.sh" <path> code-reviewer-rein-sonnet-fallback` 호출 — spec-review 축은 이번 웨이브의 존속 예외이므로 그대로 `trail/dod/.spec-reviews/<hash>.reviewed` 를 생성한다

**Code-review 경로 (일반 fallback, `[NON_INTERACTIVE] spec review` prefix 없음)**: 아래 "PASS 시 v2 발급" 절차를 그대로 따른다.

### PASS 시 v2 발급 (최초 통과 / self-review 통과 공통)

체크리스트 리뷰 결과가 PASS (이슈 없음, 또는 Low-only / Medium ≤3줄 수정 후 self-review 통과) 인 회차에서만 앞서 캡처해 둔 `$REIN_REVIEWED_DIGEST` 로 발급을 시도한다. round 이 늘어나는지(최초 통과 vs self-review) 는 위 "리뷰 에스컬레이션 흐름" 표의 판단에만 쓰이고, 발급 호출 자체는 두 경로가 동일하다. 아래 "에스컬레이션" 경로(3라운드 후에도 High 잔존)는 PASS 가 아니므로 발급을 시도하지 않는다.

~~~bash
if [ -n "${REIN_REVIEWED_DIGEST:-}" ]; then
  if ISSUE_OUT=$("${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/bin/rein" issue-evidence code_review \
      --verdict PASS --reviewed-digest "$REIN_REVIEWED_DIGEST" 2>/dev/null); then
    ISSUE_RC=0
  else
    ISSUE_RC=$?
  fi
  case "$ISSUE_RC" in
    0) echo "[rein] v2 evidence recorded (code_review, PASS) — this is this cycle's review record." ;;
    2)
       # High finding (Phase 7 wave 3 ③-a code review round 4, High-2) 계승,
       # ③-d 로 "legacy stamp 로 fallback" 문구만 제거 — 판정 로직 자체는
       # 그대로다. 응답의 reason 을 긍정적으로 파싱해 "digest-mismatch"
       # 인지 확인한다; 파싱 실패도 digest-mismatch 와 동일하게 fail-
       # closed 취급한다 (오직 non-mismatch 로 명확히 파싱된 사유만
       # "기록 안 됨, 그러나 원인은 트리 변경이 아님"으로 구분한다).
       ISSUE_REASON_OK=1
       ISSUE_REASON=$(printf '%s' "$ISSUE_OUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    reason = data.get("reason")
    if not isinstance(reason, str) or not reason:
        raise ValueError("reason missing or not a non-empty string")
except Exception:
    sys.exit(1)
sys.stdout.write(reason)
' 2>/dev/null) && ISSUE_REASON_OK=0
       if [ "$ISSUE_REASON_OK" -ne 0 ] || [ "$ISSUE_REASON" = "digest-mismatch" ]; then
         # 리뷰 대상 트리가 회차 도중 바뀌었다(또는 그 가능성을 배제할 수
         # 없다) — 이번 회차는 기록되지 않는다. legacy stamp 가 없으므로
         # "표식은 남아있다" 같은 안전망도 없다: 다음 행동은 명시적으로
         # digest 재캡처 + 재리뷰뿐이다.
         if [ "$ISSUE_REASON_OK" -ne 0 ]; then
           echo "[rein] v2 evidence issuance refused (exit 2) and the response could not be positively parsed to a reason OTHER than digest-mismatch — treating as digest-mismatch (fail-closed). This cycle is NOT recorded. Re-capture the subject digest and re-review before this can count as reviewed."
         else
           echo "[rein] v2 evidence issuance refused — reason: digest-mismatch. The reviewed tree changed during this review. This cycle is NOT recorded. Re-capture the subject digest and re-review before this can count as reviewed."
         fi
       elif [ "$ISSUE_REASON" = "subject-empty" ]; then
         # subject-empty 는 실패가 아니다(코드리뷰 Medium 시정, 2026-08-24)
         # — 리뷰 대상에 non-exempt 코드가 없다는 뜻이라 governance 는
         # 이 상태를 authority 계층에서 직접 충족으로 판정한다(spec §3.6
         # 종국 상태표). 기록이 없다고 재리뷰가 필요한 게 아니다.
         echo "[rein] no v2 evidence was issued because there is nothing non-exempt to review (digest=empty:no-subject) — this is expected, not a failure; governance treats this changeset as satisfied without an evidence record."
       else
         echo "[rein] v2 evidence issuance refused — reason: $ISSUE_REASON. This cycle is NOT recorded (no legacy stamp fallback exists) — the next review cycle must re-capture and retry v2 issuance before governance treats this as reviewed."
       fi
       ;;
    *) echo "[rein] v2 evidence issuance did not complete (exit $ISSUE_RC). This cycle is NOT recorded (no legacy stamp fallback exists) — retry issuance once the infrastructure failure is resolved." ;;
  esac
else
  echo "[rein] no reviewed-digest was captured at review start (see 'v2 evidence subject 스냅샷 캡처' 절) — v2 issuance was not attempted. This cycle is NOT recorded."
fi
~~~

`ISSUE_RC` 가 0 이 아닌 경로 중 `subject-empty`(검토할 non-exempt 코드 자체가 없어 governance 가 기록 없이 직접 충족으로 판정하는 정상 상태, 바로 위 PASS 케이스의 `elif` 분기 참조) 를 **제외한** 나머지(digest-mismatch/기타/digest 미캡처) 는 "이번 회차 기록 없음"으로 동일하게 취급한다 — 더 이상 legacy stamp 로 되돌아갈 안전망이 없으므로, 이 스킬을 호출한 caller(부모 세션)에게 그 사실을 위 echo 문구 그대로 반드시 전달해야 한다 (아래 "사용자 안내" 절에도 이 상태를 반영한다).

## 에스컬레이션 (3라운드 이후에도 High 잔존 시)

3라운드 리뷰 후에도 High 가 남아 있으면 작업을 중단하고 사람에게 에스컬레이션한다. 이 경로는 PASS 가 아니므로 v2 발급을 시도하지 않는다 — 남길 기록이 없다(legacy stamp 의 `resolution: escalated_to_human` 같은 별도 마커도 이제 존재하지 않는다). 에스컬레이션 사실과 잔존 이슈는 아래 "사용자 안내" 절의 형식으로 사람에게 직접 보고한다.

에스컬레이션 후 작업자는 잔존 이슈를 검토하여 직접 수정하거나 추가 지시를 내린다.

## 사용자 안내

이 SKILL 의 결과를 사용자에게 보고할 때 다음 짧은 형식을 **먼저** 출력한다 (위 `## 코드 리뷰 결과` 템플릿은 그 다음에 그대로 이어 붙인다). 형식은 한 문장 또는 두 문장 — 결과 1줄 + 다음 액션 1줄. 내부 식별자(`.codex-reviewed` 같은 legacy marker 명, `digest`, `evidence` 등)는 평문으로 번역한다 — `plugins/rein-core/rules/response-tone.md` 참조.

**리뷰 PASS + 기록 성공** (`ISSUE_RC=0`):
> 코드 리뷰 통과. 차단급 결함 없습니다. 통과 증거가 기록됐어요. 다음은 [code-review path 면 보안 리뷰 / spec-review fallback path 면 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/scripts/rein-mark-spec-reviewed.sh"` 로 per-spec stamp 등록].

**리뷰 PASS 이지만 기록 실패** (digest 미캡처 / `ISSUE_RC` 가 0 이 아니고 사유가 검토 대상 없음도 아님) — Phase 7 웨이브 3 ③-d 갱신, legacy stamp 안전망이 없어진 만큼 반드시 별도로 알린다:
> 코드 리뷰 자체는 통과했지만 이번 회차는 기록되지 않았어요 — [사유: 대상 상태를 확인하지 못함 / 검토 도중 대상이 바뀜 / 기록 시도 실패]. 재리뷰(digest 재캡처부터)가 필요합니다.

**리뷰 PASS + 검토할 대상이 없었음** (`ISSUE_RC=2`, 사유 = 검토할 non-exempt 코드 없음) — 기록이 없는 게 정상이므로 재리뷰를 요구하지 않는다:
> 코드 리뷰는 통과했고, 이번 회차는 검토할 대상 자체가 없어서(변경이 전부 리뷰 면제) 별도 기록이 필요 없었어요. 재리뷰 없이 다음 단계로 진행하면 됩니다.

**리뷰 NEEDS-FIX (수정 필요)**:
> 리뷰에서 N건 수정이 필요해요 — [Severity 요약, 예: "Medium 2건 + Low 1건"]. [핵심 1-2건과 다음 액션, 예: "printf 형식 mismatch + symlink 테스트 stderr 미검증. 고치고 재리뷰"].

**3회차에도 High 잔존 (사람 에스컬레이션)**:
> 리뷰 3회차에도 High N건이 남아 있어 사람 에스컬레이션이 필요합니다. 잔존 이슈를 확인하고 직접 수정하거나 추가 지시를 내려주세요.
