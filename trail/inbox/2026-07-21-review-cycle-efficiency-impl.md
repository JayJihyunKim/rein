# 코드리뷰 사이클 효율화 구현 완료 (A 자가검증 관문 + C 출력축소)

- 날짜: 2026-07-21 착수 → 2026-07-22 종결 (구현·리뷰·표식)
- DoD: `trail/dod/dod-2026-07-21-review-cycle-efficiency-impl.md`
- plan: `docs/plans/2026-07-20-review-cycle-efficiency.md` / spec: `docs/specs/2026-07-20-review-cycle-efficiency.md`

## 배포물

- 래퍼 `plugins/rein-core/scripts/rein-codex-review.sh` (+ `scripts/` sha256 미러):
  - **A 무상태 자가검증 관문** — code-review 모드에서 변경 존재 시 codex spawn 이전에
    로컬 검증 증거 강제(두 축 `[axis:typecheck]`/`[axis:test]` exit0 블록 + `diff_self_review:`,
    `verification_commands: none` 폴백, TDD red escape `verification_state`+`expected_failure`,
    red 유효 exit {1..123,125,126}). 미충족 = exit 4 + 앵커, codex 미호출.
    발동 신호: diff 변경 ∪ untracked(`git ls-files --others`) ∪ 취득실패(fail-closed).
    실행형 경로에서만 발동(source-and-call 단위 테스트 경로는 spawn 없음).
  - **C envelope 출력 밀도** — 기본 축소(MATCH 카운트 요약·발견 전량 상세·빈 섹션 생략),
    `REIN_REVIEW_VERBOSE=1` 전량 복원. FINAL_VERDICT/parser/도장 계약 불변.
- 신규 스위트: `tests/skills/test-review-selfverify-gate.sh`(69 단언) /
  `test-review-envelope-reduction.sh`(19 단언), `run-all.sh` 등록. 전 스위트 GREEN
  (skills/hooks/scripts + 미러 parity).
- spec 헤딩 `## 3. Scope Items` → `## Scope Items` 정규화 (envelope 파서 정확 일치).

## 리뷰 경과

- codex R1 (high, 10분 완주): NEEDS-FIX — High(untracked 우회)·Medium(red 토큰 유일성)·
  Medium(spec 헤딩)·테스트 보강 4건. 전부 반영.
- codex R2: 30분+ 무응답 행 → kill, **codex_timeout 대체 경로**(code-reviewer 절차,
  Sonnet 에이전트 파견은 사용자 거부로 세션 내 수행) round 2 PASS. 표식에 정직 기재
  (fallback_reason=codex_timeout, prior_reviewer=code-reviewer-rein).
- 보안 리뷰(rein:security-reviewer 에이전트): PASS. Low 1건은 후속(아래).

## 하네스 파급 (untracked 감지 때문)

- 관문 비대상 스위트는 러너/stdin 에 none 폴백 선언 통행증: evidence-manifest,
  codex-review-wrapper(러너+판정헬퍼+exit37+plugin-layout), model-profile-routing,
  model-failsoft, integration/governance-e2e.
- 신규 스위트 2개 sandbox 는 진짜 clean tree 화: 준비물 커밋 + 부산물 `.gitignore`
  (`.claude/cache/` 포함 — active-DoD 선택기 로그가 untracked 로 잡히는 함정) + 빈
  head 커밋(committed-range 폴백 빈 diff 유지).
- evidence-manifest 의 전이 불변식 2건(E5 인접성, E5b 기준 래퍼 byte 비교)은 의도된
  envelope 변경 기준으로 갱신(밀도 블록 정규화 후 비교).

## 후속 백로그

- **untracked 의 envelope 노출** (Low, 의도적 이관): 변경 목록·주제 라벨은 여전히
  diff 기반(2026-06-09 B4/B5 계약). untracked 를 envelope/claim-source/label 로
  노출하는 확장은 별도 사이클 — 관문 차원 우회는 이번에 봉합됨.
- **빈 프롬프트 안전 초기화의 env 상속 위생** (Low, 보안리뷰 권고): 조건부 기본값
  대신 무조건 재설정으로 상속 경로 원천 차단. 위협 모델(정직한 에이전트)상 비긴급.
- 대형 diff 리뷰 시간상한(이월, v1.6.1 후속)과 겹침: codex R2 급 행에 대한 시간상한
  도입 검토.

## 교훈

- codex 행은 실재(이번 세션 R2 30분+). R1 은 완주했으므로 "무조건 대체" 가 아니라
  1회 시도 후 타임아웃 판단이 현실적.
- 관문에 untracked 감지를 넣으면 테스트 sandbox 전체가 대상이 된다 — sandbox 위생
  (커밋+ignore)과 통행증(none 선언) 두 패턴으로 정리됨. `.claude/cache/` 부산물 함정 주의.
- 스스로 만든 관문에 스스로 막히는 도그푸딩 발생: spec 헤딩 수정 → 설계 리뷰 표식
  무효화 → 편집 차단. 기계적 정정도 표식 재기록 필요(정직 사유 기재).
