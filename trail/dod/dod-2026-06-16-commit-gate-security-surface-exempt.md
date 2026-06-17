# DoD — 커밋 게이트 보안 surface 없는 변경 자동 면제

- 날짜: 2026-06-16
- 유형: feature
- Scope ID: SX-command-form-failclosed, SX-staged-diff-acquire, SX-allowlist-docs-trail, SX-allowlist-version-line, SX-skip-p6-m2-when-all-exempt, SX-nonexempt-still-required, SX-coexist-light-tier, SX-audit-log, SX-regression-tests
- 출처: M2 릴리스 마찰 근본 해결 (brainstorm→spec→plan, codex 리뷰 PASS)

## 문제 (Symptom)

커밋 게이트의 보안 검토 요구(보안 표식 존재 + 신선도 비교)가 보안 surface 0 인 변경(릴리스=버전 문자열+문서)에도 보안 재검토를 강제한다(v1.5.5 릴리스 커밋이 실제 차단됨).

## 범위

`check_review_stamp()` 에 보안-surface 면제 분기 추가: 단독 `git commit`(staging 동반 없음 + 옵션 allowlist) + staged diff 전부 허용목록(문서/`trail`/버전 문자열-only)이면 보안 표식 존재(P6)+신선도(M2) 비교를 둘 다 skip. 코드 리뷰(P5)/내용검증(M3)/coverage 불변. light-tier 면제와 OR 병존. **명시 면제 외 전부 보안 관련 = fail-closed**(M2 구멍 재개방 금지). 위협모델 "정직한 에이전트 규율".

### 명시적 비범위
- content 바인딩(보안표식 baseline 기록), 적대적 우회 하드닝(버전 라인 로직숨김 등), 버전 파일 외 config 면제 확장. (spec §7)

## 변경 파일

- plugins/rein-core/hooks/pre-bash-test-commit-gate.sh
- tests/hooks/test-pre-bash-test-commit-gate.sh

## 검증 기준

- [ ] reproduction-first TDD: 각 면제/비면제/fail-closed 케이스 RED→GREEN
- [ ] 면제 성립: docs-only / 버전라인-only / docs+버전 혼합 / trail 표식 → 통과
- [ ] fail-closed: `git add && git commit` 한줄(TOCTOU) / `-a`/`--amend`/path / 여러단어 메시지 뒤 진짜 pathspec / `git diff --cached` 실패 / plugin.json 다른키·HEAD부재 / 버전파일 버전外 라인 / hook→docs rename → 보안 요구
- [ ] 불변: P5 코드표식 부재는 면제와 무관하게 차단. light-tier OR 병존.
- [ ] `bash tests/hooks/test-pre-bash-test-commit-gate.sh` + `test-security-tier-gate.sh` 전량 GREEN, `bash -n` 통과
- [ ] 통합 codex 리뷰 + 보안 리뷰 통과

## 범위 연결

plan ref: docs/plans/2026-06-16-commit-gate-security-surface-exempt.md
covers: [SX-command-form-failclosed, SX-staged-diff-acquire, SX-allowlist-docs-trail, SX-allowlist-version-line, SX-skip-p6-m2-when-all-exempt, SX-nonexempt-still-required, SX-coexist-light-tier, SX-audit-log, SX-regression-tests]

## 라우팅 추천

```yaml
agent: feature-builder
skills: []
mcps: []
rationale: >
  단일 파일 본체(pre-bash-test-commit-gate.sh) + 그 test 의 reproduction-first 신규 기능. 병렬 여지 없음(단일 파일).
  보안 게이트 변경이라 security_tier 표준(보안 리뷰 필수). 부모가 통합 codex/security 리뷰 + 커밋 소유.
approved_by_user: true
```
