# P10 git-commit-am 게이트 전역옵션 false-negative 수정 + 주석 typo

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-bash-safety-guard.sh (P10 정규식 3개)
  - plugins/rein-core/scripts/rein-codex-review.sh (주석 typo)
  - scripts/rein-codex-review.sh (주석 typo, byte-identical)
  - tests/hooks/test-pre-bash-safety-guard.sh (회귀 테스트 +19)
- 요약: 통합 codex 리뷰 NEEDS-FIX 2건 수정. (1) High — P10 이 `git commit` 인접만
  매치해 git/commit 사이 전역옵션이 끼면 `.env` 있어도 비차단. reproduction-first
  로 회귀 테스트 작성 후 codex 5라운드 재리뷰. codex 가 단계적으로 4개 추가 우회를
  발견 (R2 quoted/escaped-space value, R3 greedy-tail 신규 FP `log commit -am`,
  R4 inner/single-quote value, R5 value-less 전역옵션 `--no-pager`). enumerate 대신
  git argument grammar 모델로 종결: `git ( OPT )? commit`, OPT = value-taking 4종
  (-C/-c/--git-dir/--work-tree, 별도 value) | `=` attached | 그 외 self-contained
  dash-flag. value-taking 만 bare value 소비 → subcommand 토큰 흡수 방지 (FP 해소).
  (2) Low — 주석 `codex实측`(중국어) → `codex 실측` 양 사본 byte-identical.
- 검증: 실측 56 케이스 RED→GREEN (real command_invokes 통과), 회귀 suite 47/0,
  full suite GREEN (split/anchoring/test-commit-gate/wrapper), bash -n 3파일,
  ReDoS 무 (system grep DFA, 2000토큰 4ms). 잔존 한계: regex 의 shell-quote 비완전
  모델링 (command_invokes 한계와 동일 트랙, 실용 표면은 전부 차단).
- 리뷰 상태: codex R1~R4 각각 PASS 없이 High 발견 (전부 수정). R5 (최종 v6 grammar
  모델) 에서 codex **usage limit** 도달로 독립 codex PASS 미확보. v6 는 56케이스
  자체 검증. sonnet-fallback stamp 작성은 auto-mode 분류기가 차단 — 커밋 안 하므로
  게이트 stamp 불요 (커밋 금지 지시). 커밋 미실행.
