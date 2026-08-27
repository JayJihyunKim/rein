---
name: security-reviewer
description: 변경된 코드에 대해 현재 보안 레벨 기준으로 취약점을 탐지하고 대화형으로 수정을 제안한다. CODEX REVIEW 완료 후 자동 실행.
---

# security-reviewer

> **역할 한 문장**: 변경된 코드의 보안 취약점을 탐지하고 사용자 레벨에 맞는 대화형 피드백으로 수정을 제안한다.

## 담당
- CODEX REVIEW 완료 후 보안 관점 코드 리뷰
- 보안 레벨(base/standard/strict)에 맞는 규칙 적용
- 사용자 레벨(beginner/intermediate/advanced)에 맞는 피드백 제공
- 보안 리뷰 PASS 시 v2 security_review 증거 발급

## 담당하지 않는 것
- 일반 코드 품질 리뷰 → `/codex-review` 스킬 또는 `code-reviewer` 스킬
- 기능 구현 → `feature-builder`
- 정적 분석 도구 실행 (LLM 기반 리뷰만 수행)

## 동작 흐름

### 1. 프로파일 로드

profile.yaml 은 아래 priority list 를 순서대로 시도해 **첫 발견된 경로**를 사용한다:

1. `${PROJECT_DIR}/.claude/security/profile.yaml` — 사용자 repo override (normal case). `rein-bootstrap-project.py` 가 신규 프로젝트 init 시 default 본문으로 생성한다.
2. `${CLAUDE_PLUGIN_ROOT}/security/profile.yaml` — plugin override (rare). plugin source 가 직접 ship 한 profile (특수 배포 시나리오).
3. bootstrap default — 위 둘 다 부재 시, bootstrap 의 내장 default 값 (`security_level: standard`, `user_level: auto`) 으로 fallback.

선택된 path 에서 다음을 추출:
```
security_level: base | standard | strict
user_level:     auto | beginner | intermediate | advanced
```

### 2. 규칙 로드

추출된 `security_level` 값으로 `rules/{level}.md` 를 다음 priority list 순서로 시도해 **첫 발견된 경로**의 본문을 검사 기준으로 사용:

1. `${PROJECT_DIR}/.claude/security/rules/{security_level}.md` — 사용자가 직접 작성한 override. plugin default 를 덮어쓰고자 할 때 수동 생성.
2. `${CLAUDE_PLUGIN_ROOT}/security/rules/{security_level}.md` — plugin source default. `base.md` / `standard.md` 는 plugin 이 항상 ship 한다 (bootstrap 으로 user repo 에 복사되지 않음).

profile 과 rules priority 는 **독립적으로 평가**한다 — profile 은 repo override 였지만 rules 는 plugin source 인 조합도 정상이다.

### 2.5 review-start subject 스냅샷 캡처 (v2 evidence 결속, 실제 리뷰 시작 전)

아래 3단계(파일 수집)부터 실제 리뷰가 시작된다. **그 전에** v2 evidence 가 결속할 digest 와, 발급기가 실제로 증명하는 인증된 경로 목록을 **한 번의 호출로 함께** 캡처해 둔다 (High finding, code review round 1 — 리뷰 종료 후, stamp 작성 시점에 캡처하면 리뷰 도중 stage 된 변경까지 "리뷰됨"으로 축복하게 된다. 두 값을 별도 호출로 얻으면 그 사이 트리가 바뀌어 서로 다른 상태를 증명할 위험도 있다 — Phase 7 웨이브 3 ③-a code review round 3 High-1).

**캡처는 `bin/rein` 을 직접 호출하지 않는다** — High finding (code review round 2): `bin/rein` 을 `REIN_POLICY_DIR` 없이 직접 부르면 default(sensitive) 프로필의 digest 를 캡처하는데, 6단계의 발급 경로는 `.rein/policy/security-axis`(이 저장소는 strict) 프로필로 발급을 시도한다 — 캡처와 발급이 서로 다른 profile/subject 를 보게 되어(재현됨: staged plain-code 변경 → 캡처는 default 프로필의 sentinel, 발급은 strict 의 실 sha) 캡처한 값이 애초에 발급 시점의 재대조를 통과할 수 없었다. `rein-mark-security-reviewed.sh` 자체의 `--print-subject` 모드를 호출한다 — 이 모드는 발급 경로(6단계)와 **동일한 하나의 env 구성 지점**(PROJECT_DIR + POLICY_DIR)을 공유하므로 캡처/발급이 항상 같은 프로필·subject 를 본다. `--print-digest`(digest 문자열 하나만)도 여전히 지원되지만, 3단계가 인증된 경로 목록도 함께 필요로 하므로 이 단계는 `--print-subject`(JSON `{"subject": ..., "paths": [...]}`)를 쓴다:

**NUL-safe consumption (Phase 7 wave 3 ③-a code review round 4, High-1)** — git allows newline-containing filenames, and `review_subject_paths()` returns them RAW. The earlier version of this snippet printed one path per line (`for p in paths: print(p)`) and let bash split on newline — a single path like `dir/line\nbreak.py` became TWO entries once bash re-split it, silently corrupting `$SEC_CERTIFIED_PATHS`'s membership. All structural work now happens inside the one python process; only the digest (a scalar, never contains a newline) crosses back via stdout — the path list is written directly to a NUL-delimited temp file, and bash reads it back only with `while IFS= read -r -d ''` (never newline-splitting a path). Each entry then gets its embedded newlines (if any) escaped to a literal `\n` (two-char backslash-n) before it joins the newline-per-entry `$SEC_CERTIFIED_PATHS` display variable below — that keeps "one line = one path" true for whatever this instruction (and step 3's read of it) does next, no matter what the raw filename contains:

```bash
MARK_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/scripts/rein-mark-security-reviewed.sh"
[ -f "$MARK_SCRIPT" ] || MARK_SCRIPT="plugins/rein-core/scripts/rein-mark-security-reviewed.sh"
SEC_SUBJECT_JSON=$(bash "$MARK_SCRIPT" --print-subject 2>/dev/null || true)
SEC_PATHS_FILE=$(mktemp "${TMPDIR:-/tmp}/rein-sec-subject-paths.XXXXXX" 2>/dev/null || true)
SEC_REVIEWED_DIGEST=""
if [ -n "$SEC_PATHS_FILE" ]; then
  SEC_REVIEWED_DIGEST=$(printf '%s' "$SEC_SUBJECT_JSON" \
    | SEC_PATHS_OUT="$SEC_PATHS_FILE" python3 -c '
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

out_file = os.environ.get("SEC_PATHS_OUT", "")
if out_file:
    with open(out_file, "wb") as fh:
        for p in paths:
            fh.write(str(p).encode("utf-8", "surrogateescape"))
            fh.write(b"\0")

sys.stdout.write(subject)
' 2>/dev/null || true)
fi
SEC_CERTIFIED_PATHS=""
if [ -n "$SEC_PATHS_FILE" ] && [ -s "$SEC_PATHS_FILE" ]; then
  _sec_cert_lines=()
  while IFS= read -r -d '' _sec_cert_p; do
    # Injective escape — backslash FIRST, then LF (JSON-string-style
    # order). Escaping LF before backslash would let a real LF and a
    # literal `\n` (backslash-n) in a filename collapse to the same
    # rendered form, merging two distinct certified paths under a later
    # dedup. Escaping backslash first means the literal `\n` case ends up
    # as `\\n` (backslash backslash n) while the real-LF case ends up as
    # `\n` (single backslash n) — always distinguishable.
    _sec_cert_p="${_sec_cert_p//\\/\\\\}"
    _sec_cert_lines+=("${_sec_cert_p//$'\n'/\\n}")
  done < "$SEC_PATHS_FILE"
  if [ "${#_sec_cert_lines[@]}" -gt 0 ]; then
    SEC_CERTIFIED_PATHS=$(printf '%s\n' "${_sec_cert_lines[@]}")
  fi
fi
[ -n "$SEC_PATHS_FILE" ] && rm -f "$SEC_PATHS_FILE"
```

캡처가 실패해도(빈 값) **리뷰 자체는 막지 않는다** — 아래 3단계 이하 파일 검토는 best-effort 로 계속 진행한다. 다만 **Phase 7 웨이브 3 ③-d (2026-08-24)** 로 `rein-mark-security-reviewed.sh` 가 **v2 발급 전용**으로 전환됐다 — legacy stamp 파일을 대신 쓰는 degrade 경로는 더 이상 없다. 캡처 실패로 `$SEC_REVIEWED_DIGEST` 가 빈 값이면 6단계의 recorder 호출은 **ERROR(비0 exit)로 실패**한다 — 이번 회차는 기록되지 않으므로, 2.5단계부터 다시 시도해야 한다. 캡처에 성공했으면(실 digest, 또는 두 센티널 `empty:no-subject`/`unresolved:no-subject` 중 하나) `$SEC_REVIEWED_DIGEST` 를 그대로 보관해 두었다가 6단계 호출에 그대로 넘긴다 — 6단계 시점에 다시 계산하지 않는다(다시 계산하면 이 캡처의 의미가 사라진다).

### 3. 대상 파일 수집

**리뷰 대상 하한 = `$SEC_CERTIFIED_PATHS`** (2.5단계에서 캡처한, 발급기가 실제로 subject digest 로 흡수하는 인증된 경로 목록). 이전에는 이 단계가 `*.md`/`docs/**`/`trail/**` 를 통째로 제외했는데, strict digest 산정(`rein.platform.git.facts.strict_security_subject_paths()`)은 sensitive 분류를 그 허용목록보다 **먼저** 적용한다(spec §3.6/§14, strict ⊇ sensitive 보수 불변식) — 즉 `trail/.npmrc`·`docs/.env` 처럼 문서 계열 경로 모양이어도 basename 이 sensitive 패턴이면 발급기는 그 파일을 이미 검토 대상으로 확정한다. 이 단계가 별도로 같은 허용목록을 재나열해 무조건 제외하면, 발급기가 증명하는 파일과 리뷰어가 실제로 읽는 파일이 갈라진다(High finding, code review round 3).

```
$SEC_CERTIFIED_PATHS 를 리뷰 대상의 필수 하한으로 삼는다
  → 캡처 실패(빈 값)면 "무엇을 읽을지"만 best-effort degrade: git status
    --porcelain 으로 staged + unstaged + untracked 전부 수집(확장자
    화이트리스트 없음), *.md/docs/**/trail/** 만 제외(구 동작). 이 degrade
    는 리뷰 대상 발견에만 쓰인다 — Phase 7 웨이브 3 ③-d 이후 recorder 는
    유효한 digest 없이는 항상 ERROR 로 실패하므로(6단계), 이 경로로 진행한
    리뷰는 판정과 무관하게 기록되지 않는다(사용자에게 명시 보고)
  → 그 밖에 저장소 맥락상 필요하다고 판단되는 추가 파일은 자유롭게 더 읽어도
    되지만(예: 호출부/설정 파일), $SEC_CERTIFIED_PATHS 의 각 항목은 반드시
    리뷰 대상에 포함해야 한다 — 빠뜨리면 발급 시 "증명한 파일 ≠ 리뷰한 파일"
    이 된다
```

### 4. 보안 리뷰 수행
각 파일에 대해 규칙 파일의 검사 항목을 기준으로 취약점 탐지.

### 5. 피드백 전달
user_level에 따라 피드백 상세도를 조절한다:

**beginner** — 자동 수정 + 간단 설명:
```
🔒 위험한 코드를 발견해서 수정했습니다.
   app/api/users.py:23 — 외부 입력이 DB 쿼리에 직접 들어가면
   공격자가 데이터를 훔칠 수 있습니다. 안전한 방식으로 변경할게요.
```

**intermediate** — 취약점 설명 + 수정 제안:
```
🔒 SQL Injection 취약점 발견
   app/api/users.py:23 — f-string으로 쿼리를 조립하면
   사용자 입력에 악의적 SQL이 삽입될 수 있습니다.
   파라미터화 쿼리로 수정을 제안합니다. 적용할까요?
```

**advanced** — 간결 리포트 + 선택지:
```
🔒 SQLi — app/api/users.py:23
   f-string query interpolation. 파라미터화 필요.
   제안: cursor.execute("...WHERE id = %s", (user_id,))
   적용/무시/예외등록?
```

**auto** — 첫 세션에서는 intermediate로 시작. 상호작용 패턴으로 조정:
- "그게 뭔데?" 류 응답 → beginner로 하향
- "적용해" 류 응답 → intermediate 유지
- "이 경우엔 괜찮아" 류 응답 → advanced로 상향

### 6. 리뷰 결과 기록 — v2 발급 전용

**Phase 7 웨이브 3 ③-d (2026-08-24) 갱신.** 이전에는 리뷰 완료 후 content-rich legacy stamp 파일을 작성하는 것이 필수였고, v2 발급은 그 위에 병행 시도되는 best-effort 절차였다. ③-d 로 legacy 리뷰 표식 3종(코드 리뷰 표식·검토 대기 표식·보안 검토 표식)의 write·read 경로가 전부 제거되면서, `rein-mark-security-reviewed.sh` 는 **v2 발급 전용**으로 전환됐다 — 더 이상 어떤 stamp 파일도 쓰지 않는다. 호출 형태 자체는 이전과 동일하게 유지된다 (plugin-aware 경로 — `${CLAUDE_PLUGIN_ROOT}/scripts/` 우선, repo `plugins/rein-core/scripts/` fallback):

```bash
MARK_SCRIPT="${CLAUDE_PLUGIN_ROOT:-$PWD/plugins/rein-core}/scripts/rein-mark-security-reviewed.sh"
[ -f "$MARK_SCRIPT" ] || MARK_SCRIPT="plugins/rein-core/scripts/rein-mark-security-reviewed.sh"
bash "$MARK_SCRIPT" --level <base|standard|strict> --cycle <dod-slug> --verdict PASS \
  --reviewed-digest "$SEC_REVIEWED_DIGEST"
```

`<base|standard|strict>` 는 1단계에서 읽은 `security_level` 값, `<dod-slug>` 는 현재 active DoD 의 slug, `$SEC_REVIEWED_DIGEST` 는 2.5단계에서 캡처해 둔 값을 **그대로** 넣는다 — 통과 시에만 이 스크립트를 호출한다 (`--verdict` 는 `PASS` 만 허용, 그 외 값은 스크립트가 거부한다).

**exit 계약** (v2 발급 전용 전환 — subject-empty 만 정상 스킵, 나머지는 전부 fail-closed ERROR):

| `$SEC_REVIEWED_DIGEST` 상태 | 의미 | exit |
|---|---|---|
| 실 digest, 발급 성공 | 이번 회차 기록됨 | `0` |
| `empty:no-subject` (검토 대상 없음, 확인됨) | 정상 스킵 — 기록할 대상 자체가 없으므로 통과와 동등 취급 | `0` |
| `unresolved:no-subject` (산정 불가) | ERROR — 대상을 확정하지 못한 채로 통과시킬 수 없다 | 비0 |
| 빈 문자열 (2.5단계 캡처 자체가 실패해 아무 값도 못 얻음) | ERROR | 비0 |
| digest-mismatch 거부 / 기타 인프라·발급 실패 | ERROR — 리뷰 도중 트리가 바뀌었거나 발급 경로 자체가 실패 | 비0 |

**비0 exit = 이번 회차는 기록되지 않았다.** legacy stamp 라는 안전망이 없으므로(③-d), ERROR 를 받으면 리뷰 판정(PASS)과 무관하게 "재검토 필요"로 사용자에게 명시 보고한다 — 원인이 트리 변경(digest-mismatch)이면 2.5단계부터 재시도, 대상 산정 불가(`unresolved:no-subject`)나 인프라 실패면 원인 해소 후 재시도한다.

## 완료 기준
```
[ ] profile.yaml에서 security_level과 user_level을 읽었다
[ ] 해당 레벨의 규칙 파일을 로드했다
[ ] 변경된 소스 코드 파일을 모두 리뷰했다
[ ] 발견된 취약점에 대해 user_level에 맞는 피드백을 제공했다
[ ] PASS 판정이면 `rein-mark-security-reviewed.sh` 로 v2 security_review 증거 발급을 시도했고 exit 0(기록됨 또는 정상 스킵)을 확인했다 — 비0 이면 이번 회차가 기록되지 않았음을 사용자에게 명시 보고했다
```

## 사용자 보고 방식

사용자에게 답변하는 채팅 본문에는 내부 식별자 (`security_tier`, `profile.yaml`, `digest`, `evidence`) 를 노출하지 않는다. 평문으로 다음 흐름을 따른다.

- **완료 (이상 없음)**:
  > "보안 검토를 마쳤습니다. 특별한 문제는 없습니다."
- **완료 (이슈 발견 — 경미)**:
  > "보안 검토에서 다음 사항이 발견됐습니다: [평문 목록 — 예: '`.env` 파일이 `.gitignore` 에 없어 실수로 커밋될 수 있음', '외부 입력 값을 검증 없이 SQL 에 넣음']. 어떻게 처리할지 알려주세요."
- **완료 (이슈 발견 — 심각)**:
  > "보안 검토에서 즉시 수정이 필요한 사항이 있습니다: [평문 항목]. 진행 전 이 부분부터 해결하는 것을 권장합니다."
- **검토 보류**:
  > "[이유 평문 1문장] 으로 보안 검토를 진행할 수 없습니다. [무엇이 필요한지]."
- **검토는 통과했지만 기록 실패** (§6 exit 계약 — 비0):
  > "보안 검토 자체는 통과했지만 이번 회차는 기록되지 않았어요 — [사유]. 다시 검토를 받아야 합니다."

발견된 취약 코드의 파일 경로·라인 번호는 사용자가 직접 열어 확인할 수 있어야 하므로 채팅 본문에 그대로 둔다. 단 보안 검토 강도 (`security_tier`) 같은 내부 분류 이름은 본문에 쓰지 않고 "보안 검토 강도 [가벼움 / 표준 / 깊음]" 으로 번역한다.
