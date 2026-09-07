# 2026-09-07 — 리뷰 사이클 자기증폭 고리 봉합 구현 완료 (사이클 ③)

대상 DoD `trail/dod/dod-2026-09-07-review-cycle-selfamplification.md`. 코드 커밋 dev `2c775ae`(웨이브 1, 13파일) + `7b7c249`(웨이브 2, 3파일). 설계 `docs/specs/2026-08-27-review-cycle-selfamplification.md`, 계획 `docs/plans/2026-09-06-review-cycle-selfamplification.md`(둘 다 5회차 후 사용자 승인 종결 표식). 진행 메모 `2026-09-07-review-selfamp-wave1-progress`(웨이브 1 상세).

## 무엇이 바뀌었나 (사용자 대면)
- **리뷰 요청서 거부 규칙**: 증거 블록이 있어도 블록 밖에 실행 결과 서술(검증명사+통과어 공존 / 계약 문맥어 없거나 결과 서술어 붙은 비율·백분율 / 결과 서술어 붙고 계약 문맥어 없는 수량)이 남으면 래퍼가 codex 호출 전에 거부한다. 고정 계약값("50줄 이내", "오차 상한 ±20%")과 단독 수량은 경고 유지. 사용 규약 `skills/codex-review/SKILL.md` 동기화.
- **주석 규칙**: `rules/code-style.md` 가 지속 계약(why/what)만 허용하고 회차·수리 이력·측정 수치는 trail 로 보내며, 검사는 diff 의 추가·수정된 주석 줄만, 박제된 서사는 정정 대신 삭제/이동. 요약본·code-reviewer 체크리스트 동기화.
- **문서-only 조기 통과**: 리뷰 subject 가 비어 있고(문서·기록만 변경) 현재 관측이 첫 관측의 부분집합일 때만 자가검증 관문(typecheck/test 증거 요구)을 건너뛴다. 취득 실패·관측 불일치·키 부재는 전부 발동(fail-closed). CLI `print_subject` 는 같은 관측의 전체 경로를 3-tuple 로 반환하고 `bin/rein` 이 `changeset_paths` 로 직렬화(보안 리뷰 출력 불변).

## 어떻게 했나
- 웨이브 1: 정본 parallel-execute 같은 트리 3 태스크 + 블록 밖 격리 worktree 1건(`bin/rein` 라이브 파일) 동시, 워커 sonnet. 격리 트리는 완성 파일 `cp` 한 명령으로 반입. codex 리뷰 R1 NEEDS-FIX(Medium 3, 부모 직접 수정) → R2 PASS, 보안 PASS. trail 회전분은 별도 커밋 `41dcded`.
- 웨이브 2: 단독 태스크(래퍼 A7 + 관측 일관성). codex R1 PASS(Low 1), 보안 PASS. 워커가 bash 단일 따옴표 안 python 주석의 아포스트로피가 문자열을 조기 종료시키는 결함을 구현 중 스스로 잡아 고침.
- 전량 검증: skills/hooks/scripts run-all 3종 + python 단위 스위트 전부 종료값 0(증거는 각 웨이브 리뷰 요청서 블록에 기록).

## 관찰 (이 사이클이 봉합하려던 것의 실사례)
- 새 거부 규칙이 **두 웨이브 모두에서 부모의 리뷰 요청서를 먼저 잡았다**(규칙 설명 문장 "검증명사+통과어" / "계약 6건 … 조회 실패") — 둘 다 계약 형태로 고쳐 재호출(예산 미소모). spec §10 이 예고한 오탐 클래스가 실제로 저비용 우회 가능함을 확인.
- 축1 워커가 금지된 `git stash` 를 써서 옛 stash 가 부분 적용됐다가 스스로 치움 → 부모 독립 검증으로 무손상 확인([[feedback_worker_stash_forbidden]] 재발 — 프롬프트 금지만으로는 부족, 별도 후속).
- 훅 실행 루트가 저장소 트리임을 프로세스 샘플링으로 실측(등록 경로와 다름) — plan 3회차의 "격리 불필요" 전제를 4회차 리뷰가 잡아냄.

## 후속 (기록만)
- 문서 전용 사이클(사용자 승인 필요 — spec 편집은 표식 무효화·회차 예산 소진): spec §7 (h2)/§9 "혼합 tier 가 envelope 에 실린다" 문구를 "혼합 scanner flags + advisory-only envelope" 로 정정, spec 제목 `## 9. Scope Items` → `## Scope Items`(래퍼 자동 추출기 규약) 정규화 또는 추출기가 번호 접두를 허용하도록.
- Low: `_readiness_check` advisory 분기가 `QUANT_FLAGS` 를 읽음(동작 동일, `QUANT_ADVISORY_FLAGS` 미사용) / 테스트 SV29 픽스처가 역방향(첫 관측 digest → 뒤 관측 문서-only)을 완전히 재현하지 않음(`mk_docs_dirty` + 코드 subject 조합으로 교체).
- 워커 stash 금지의 구조적 강제(pre-bash 가드에서 서브에이전트의 `git stash` 차단) 검토.
- 축3 실전 관찰: 문서-only 회차의 `/codex-review` 가 typecheck/test 증거 없이 진행되는지 다음 문서 사이클에서 확인해 기록.
