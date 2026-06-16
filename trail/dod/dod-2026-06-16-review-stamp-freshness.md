# DoD — 리뷰 통과 표식 신선도/내용 바인딩 + 생성기 fail-open 봉합 (M2/M3/M4)

- 날짜: 2026-06-16
- 유형: fix
- Scope ID: M2-security-stamp-freshness-compare, M2-security-stamp-verdict-pass, M2-security-stamp-content-standard, M2-security-reviewer-instruction-update, M2-light-tier-skip-interaction, M3-code-stamp-verdict-dualread, M4-spec-producer-conservative-marker, M4-spec-marker-consumer-block, M4-spec-marker-bypass-consume, M2-M3-regression-tests, M4-regression-tests
- 출처: 마커 감사 후속 백로그 (`trail/daily/2026-06-15.md` §M2/M3/M4) → brainstorm → spec → plan (모두 codex 리뷰 PASS)

## 문제 (Symptom)

리뷰 통과 표식(도장)이 **정직한 에이전트** 한테도 조용히 안전장치를 끄게 한다:
- **M2**: 커밋 게이트가 보안 통과 표식을 **존재만** 검사 → 새 코드 편집 + 코드리뷰 재실행 후에도 이전 사이클 보안 통과가 적용(stale-pass).
- **M3**: 커밋 게이트가 코드 표식의 통과 판정을 안 보고 존재+신선도만 → NEEDS-FIX/escalated 표식이 통과.
- **M4**: 스펙 리뷰 표식 생성기가 3개 실패 경로에서 보수 마커 없이 통과(fail-open) → 미리뷰 스펙 변경이 후속 편집을 못 막음.

## 범위

위협모델은 "정직한 에이전트 규율"까지 (적대적 우회 하드닝 범위 밖). spec/plan 의 Chosen Direction 그대로:
- **M2**: 커밋 시 보안 표식이 코드 표식보다 같거나 신선 + 같은 cycle(non-empty) + `verdict=PASS` 검증. 보안 표식 content-rich 표준화 + 보안리뷰어 지침 갱신. light-tier 면제면 비교 skip.
- **M3**: 코드 표식 통과 판정 dual-read(`verdict: PASS` 우선, 없으면 legacy `resolution: passed`) + 시각 파싱. 판정 실패/파싱불가 → fail-closed.
- **M4**: 생성기 3개 fail-open 경로(비캐시 python/JSON 파싱/캐시경로 python)에 보수 마커 생성 + pre-edit 차단 + 1회성 바이패스(consume-on-use) + 성공 시 auto-heal.

### 명시적 비범위
- 도장 원자성·락(D1/D2), M2 편집-무효화(Option A), M3 강한 바인딩(diff_base/content_sha), 적대적 우회 하드닝. (spec §9)

## 변경 파일

- plugins/rein-core/hooks/pre-bash-test-commit-gate.sh
- plugins/rein-core/hooks/post-edit-spec-review-gate.sh
- plugins/rein-core/hooks/pre-edit-dod-gate.sh
- plugins/rein-core/agents/security-reviewer.md
- tests/hooks/test-security-tier-gate.sh
- tests/hooks/test-pre-bash-test-commit-gate.sh
- tests/hooks/test-spec-review-gate.sh

## 검증 기준

- [ ] reproduction-first: 각 묶음 worker 가 자기 scope 테스트에 실패 케이스 먼저 작성 → 구현 → GREEN
- [ ] M2: (보안<코드)→차단, (보안≥코드 cycle일치 non-empty verdict=PASS)→통과, (cycle 불일치/빈값)→차단, (보안 verdict=NEEDS-FIX)→차단, (보안표식 빈/touch)→차단, (light-tier 면제+보안부재)→통과
- [ ] M3: (verdict:PASS)→통과, (verdict:NEEDS-FIX)→차단, (resolution:escalated_to_human)→차단, (legacy resolution:passed)→통과, (판정필드 부재)→차단, (시각 파싱불가)→차단
- [ ] M4: 3개 fail-open 경로 각각 → 보수 마커 생성; 정상 → 마커 해소; 마커 존재 → 편집 차단; 바이패스 → 1회 통과+소비; 바이패스 후 → 재차단
- [ ] 관련 hook suite 전량 GREEN (`test-security-tier-gate.sh`, `test-pre-bash-test-commit-gate.sh`, `test-spec-review-gate.sh`, `test-pre-edit-dod-gate.sh`)
- [ ] 변경 hook 3종 `bash -n` 통과
- [ ] 통합 codex 리뷰 + 보안 리뷰 통과

## 범위 연결

plan ref: docs/plans/2026-06-16-review-stamp-freshness.md
covers: [M2-security-stamp-freshness-compare, M2-security-stamp-verdict-pass, M2-security-stamp-content-standard, M2-security-reviewer-instruction-update, M2-light-tier-skip-interaction, M3-code-stamp-verdict-dualread, M4-spec-producer-conservative-marker, M4-spec-marker-consumer-block, M4-spec-marker-bypass-consume, M2-M3-regression-tests, M4-regression-tests]

## 라우팅 추천

```yaml
agent: feature-builder-fix
skills: [parallel-execute]
mcps: []
rationale: >
  plan 의 ## 실행 전략이 파일 disjoint 2 묶음(commit-gate-bundle / spec-gate-bundle)을 단일 Wave 병렬로
  정의. 각 묶음은 reproduction-first 버그수정(게이트 hook + 그 test). 부모가 웨이브 검증·통합 리뷰·커밋 소유.
approved_by_user: true
```
