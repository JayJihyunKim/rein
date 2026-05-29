# SR-1.b orphan 백스톱 mtime 거짓양성 → 내용 기반 비교 전환

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-edit-dod-gate.sh (orphan 백스톱 3단계 재작성)
  - plugins/rein-core/scripts/rein-mark-spec-reviewed.sh + scripts/rein-mark-spec-reviewed.sh (content_sha 기록, byte-identical 쌍)
  - plugins/rein-core/scripts/rein-heal-legacy-pending.py + scripts/rein-heal-legacy-pending.py (content_sha 기록, byte-identical 쌍)
  - tests/hooks/test-spec-review-gate.sh (orphan 8 + writer 2 신규 테스트)
- 요약: spec-review 게이트의 orphan `.reviewed` 백스톱이 파일 mtime 을 reviewed= 와 비교 → checkout/cherry-pick 이 내용 변경 없이 mtime 갱신 시 거짓 stale 로 무관 소스 편집 연쇄 차단(2026-05-29 incident: 25 문서). mtime → 내용 기반 3단계로 교체: TIER1 content_sha byte-hash strict 비교(FP-free+FN-safe), TIER2 회고/healer 마커 한정 git committer-time fallback(ls-files tracked + dirty + commit-epoch, 기존 마커 incident 해소), TIER3 mtime(non-retro/non-git 보존). writer 2종은 content_sha 기록(mark 는 해시 실패 시 fail-close, healer 는 best-effort degrade).

## 프로세스

- 설계 긴장(content-hash vs commit-time)을 codex Mode B(gpt-5.5/high)로 선검증 — codex 가 commit-time 단독안의 FN(clean 체크아웃 시 다른 옛 내용 통과)을 지적 → "강화 A안"(content_sha 1순위 + 회고 한정 fallback) 채택. 사용자 전제("코덱스 한도 복귀")가 실제와 모순(5/31까지 제한)임을 보고 후 재시도에서 성공.
- TDD reproduction-first: orphan 백스톱 무테스트였음 → 실패 테스트 10개 먼저(T1~T6 RED, T7/T8 보존), 구현 후 GREEN.
- 코드 리뷰: codex Mode A high — FINAL_VERDICT PASS, 차단 0(TIER2 잔존 FN 은 문서화된 의도적 heuristic).
- 보안 리뷰: security-reviewer standard — 차단 0. 주입/traversal/BC-INFO1 회귀 실측 검증.

## 검증

- tests/hooks/test-spec-review-gate.sh: 37/37
- pre-edit-dod-gate 14/14, dod-gate 8/8, stat-portability 14/14
- 전체 훅 스위트 94 파일: 실패 2건은 stash 로 기존 이슈 확정(background-jobs 등록 / meta-check-perf flaky) — 본 변경 무관

## 잔존 / 후속

- TIER2 회고 마커 fallback 은 "security-equivalent 아닌 compatibility heuristic"(codex). clean 체크아웃 옛 내용 + 회고 마커 조합의 FN 이론상 잔존 — low-risk 수용. 비-회고 content_sha-less 마커는 다음 review 시 TIER1 migration.
- need-to-confirm.md 의 SR-1.b-MTIME-FP → 해소(confirmed.md 이관 대상). SR-1.b(orphan 백스톱 구현 자체)도 이미 RESOLVED 표기였음.
- push 미실행 (dev 누적). main 머지는 series 종결 후 별도 승인.
