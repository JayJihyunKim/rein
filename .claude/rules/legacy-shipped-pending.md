# Legacy-shipped pending marker auto-heal

## 배경

`pre-edit-dod-gate.sh` 는 `trail/dod/.spec-reviews/*.pending` 마커가 있고 매칭되는 `.reviewed` 가 없으면 `scripts/` / `.claude/` / 루트 config 편집을 차단한다. 이는 **미리뷰 설계/구현 문서** 에 대해 설계 → 코딩 순서를 강제하는 gate.

rein 의 review discipline 이 정착되기 전 (v1.0.0 이전) 에 작성된 문서들은 `.pending` 만 남고 `.reviewed` 가 없는 상태로 shipped 된 경우가 많다. 이 legacy marker 들이 축적되면 신규 작업 시 gate 가 과도하게 차단한다.

## 규칙

release tag (예: `v1.0.0`) 에 **이미 포함된** 문서의 pending marker 는 자동으로 `.reviewed` stamp 로 전환된다. 신규 / 미커밋 / tag 이후 수정 문서는 기존 워크플로 유지.

"포함" 판정 기준 (`scripts/rein-heal-legacy-pending.py`) — **3 축 모두 충족해야 heal**:

1. **Tag 정합성**: 아래 둘 중 하나
   - Tag tree 에 직접 존재 (`git cat-file -e <tag>:<path>` 성공) — 일반 main 포함 문서
   - Dev-only 문서 timestamp 판정: **dev 파일 last-commit ISO timestamp ≤ tag 의 commit timestamp** (`docs/specs/**`, `docs/plans/**` 처럼 branch-strategy main 제외 대상)
2. **Pending marker freshness**: pending marker 의 `created=` 타임스탬프 가 선택된 tag 의 commit timestamp **이전 또는 같음**. 릴리즈 이후 새로 편집돼 생성된 fresh pending 은 **heal 대상 아님** (gate 가 원래 의도한 "설계 → 코딩 순서 강제" 를 보존).
3. **파일 존재**: 대상 문서가 현재 repo 에 존재.

미커밋 문서 (git log 에 등장 안 함) / `created=` 필드 없음 / fresh pending (릴리즈 이후 생성) → **skip** (정상 review 워크플로 따름).

### Timezone 주의

ISO 8601 `+offset` 포함 timestamp 는 raw 문자열 비교 불가 (DST / 다른 offset). healer 는 `datetime.fromisoformat` 으로 timezone-aware datetime 파싱 후 비교.

Stamp 내용 (`rein-mark-spec-reviewed.sh` 와 schema 일치):

```
path=<절대 경로>
reviewer=retrospective-shipped-<tag>
reviewed=<ISO 8601 UTC, YYYY-MM-DDTHH:MM:SS>
mechanism=rein-heal-legacy-pending
```

필드명 규약: `reviewed=` (not `reviewed_at=`) — rein 의 모든 review stamp writer 가 공유하는 schema.

## 호출 시점

- **세션 시작**: `session-start-load-trail.sh` 가 `python3 scripts/rein-heal-legacy-pending.py --quiet` 호출 (실패해도 세션 continue)
- **수동 실행**: `python3 scripts/rein-heal-legacy-pending.py [--dry-run]`

## 보안 / 규율 고려

- 자동 stamp 는 **이미 shipped 된 릴리즈의 문서에만** 적용 — active/신규 문서는 절대 bypass 안 됨
- reviewer 필드로 "회고적 stamp" 임을 명시 (정식 codex review stamp 와 구분 가능)
- 신규 spec/plan 은 기존 `/codex-review` + `rein-mark-spec-reviewed.sh` 경로 유지
- 이 규칙은 **gate 완화가 아니라 gate 의 정확도 개선** — legacy noise 제거로 신규 미리뷰 건이 실제로 block 되도록

## 관련 파일

- `scripts/rein-heal-legacy-pending.py` — healer 본체
- `.claude/hooks/session-start-load-trail.sh` — 호출 지점
- `.claude/hooks/pre-edit-dod-gate.sh` — pending marker 기반 gate
- `trail/dod/.spec-reviews/` — stamp 저장소

## 근거

- Incident: `auto-pre-edit-dod-gate-351623296a9bc1d8-2` (pattern_hash=351623296a9bc1d8, 2026-04-21 세션 4회 재발)
- 승격 결정 날짜: 2026-04-21
- 승격 사유: hook 소스의 legacy-awareness 부재로 인한 반복 block. 개별 소급 review 는 10+ 문서에 대해 비용 과다.
