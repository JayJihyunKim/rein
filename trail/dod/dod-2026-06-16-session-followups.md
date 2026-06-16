# DoD — 세션 후속: 검증기 표 형식 leniency + M4 소비측 하드닝

- 날짜: 2026-06-16
- 유형: fix
- Scope ID: FU-validator-scope-items-leniency, FU-spec-writer-format-note, FU-m4-bypass-removal-proof, FU-m4-echo-sanitize
- 출처: 2026-06-16 M2/M3/M4 세션 후속 (재발 부채 + 통합 보안리뷰 INFO 2건)

## 문제 (Symptom)

- **재발 부채**: 커버리지 검증기 `rein-validate-coverage-matrix.py` 가 `## Scope Items` 를 **번호 없는 정확 매칭**만, Scope ID 셀을 **백틱 없는 bare token**만 인식한다. spec-writer 가 자연스러운 마크다운(`## 3. Scope Items`, `` `M2-...` `` 백틱)으로 쓰면 validator 가 못 읽어 plan-writer 가 매번 수동 정규화 → 스펙 표식 무효화 → 재리뷰 사이클(이번 세션 + 과거 반복).
- **INFO-1 (통합 보안리뷰)**: M4 소비측 바이패스(`pre-edit-dod-gate.sh` `.skip-spec-gen-gate`)가 `rm -f` 후 삭제 증명이 없다. M1(`.skip-spec-gate`)은 `[ ! -e ]` 로 제거 증명 + fail-closed 하는데 M4 는 누락 → 비일관.
- **INFO-2 (통합 보안리뷰)**: M4 소비측이 `cause=`/`reason=` 값을 sanitize 없이 stderr echo. 커밋게이트 `sanitize_marker_path` 와 달리 제어문자/터미널 이스케이프가 그대로 출력될 수 있다(심층방어 갭).

## 범위

- **FU-validator-scope-items-leniency**: 검증기(repo `scripts/` + plugin `plugins/rein-core/scripts/` 2사본 동일) 가 (a) `## [N. ]Scope Items` 번호 heading 과 (b) 백틱 감싼 Scope ID 셀(`` `M2-...` ``)을 수용. Scope Items + 매트릭스 heading 둘 다 번호 tolerant. 기존 strict 포맷도 계속 통과(backward compatible).
- **FU-spec-writer-format-note**: `plugins/rein-core/agents/spec-writer.md` 필수 섹션 계약에 "`## Scope Items`(번호 무관), Scope ID 는 표 셀에 bare 또는 백틱 — 둘 다 검증기 수용" 1줄 명시(defense-in-depth).
- **FU-m4-bypass-removal-proof**: M4 바이패스 소비를 M1 패턴과 일관 — `[ -e ]` 감지 → `rm -f` → `[ ! -e ]` 제거 증명 성공 시에만 1회 통과, 실패면 fail-closed(차단).
- **FU-m4-echo-sanitize**: M4 의 `cause`/`reason` echo 를 인라인 sanitize(`LC_ALL=C tr -d '[:cntrl:]' | cut -c1-200`, sanitize_marker_path 미러)로 출력.

### 명시적 비범위
- routing 블록(`.skip-routing-gate`)의 동일 무sanitize echo 는 이번 범위 밖(기존 패턴, 별도 pass). 검증기를 spec-writer 가 표가 아닌 heading-per-scope 로 쓰는 경우까지 수용하도록 확장하는 것도 비범위(이번은 번호+백틱 한정).

## 변경 파일

- scripts/rein-validate-coverage-matrix.py
- plugins/rein-core/scripts/rein-validate-coverage-matrix.py
- plugins/rein-core/agents/spec-writer.md
- plugins/rein-core/hooks/pre-edit-dod-gate.sh
- tests/hooks/test-coverage-matrix.sh
- tests/hooks/test-spec-review-gate.sh

## 검증 기준

- [ ] reproduction-first: 검증기에 (번호 heading + 백틱 ID) fixture 가 현행 코드에서 실패 확인 → leniency 적용 후 통과 + 기존 strict 포맷 회귀 통과
- [ ] M4 바이패스: 정상 바이패스 → 1회 통과 + 마커 소비; 제거 불가(디렉토리) 바이패스 → fail-closed(exit 2)
- [ ] M4 echo sanitize: reason 에 제어문자 주입 → 출력에서 제거됨(테스트)
- [ ] 두 검증기 사본 byte-동일 유지(drift 방지)
- [ ] `bash tests/hooks/test-coverage-matrix.sh` / `test-spec-review-gate.sh` / `test-pre-edit-dod-gate.sh` 전량 GREEN
- [ ] `bash -n` 변경 hook + `python3 -c` 검증기 import OK
- [ ] codex 코드리뷰 + 보안 리뷰 통과

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: []
mcps: []
rationale: >
  reproduction-first 버그/하드닝 수정 4건. 검증기 파서 leniency + M4 소비측 2건 + 지침 1줄.
  파일 disjoint 아님(M4 2건은 같은 pre-edit-dod-gate.sh) — 작성자가 직접 순차 구현. 리뷰/커밋은 상위 흐름.
approved_by_user: true
```
