# P10 .env commit-am 가드 정규식 단순화 (SIMPLIFY)

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-bash-safety-guard.sh
  - tests/hooks/test-pre-bash-safety-guard.sh
- 요약: codex Round 2 권고 + 사용자 승인으로 P10 의 복잡한 R5/v6
  git-argument-grammar (CHUNK matcher) 를 폐기하고 단순형 3-arm 정규식으로 교체.
  PREFIX = git ( value-taking opt[bare value] | dash-led 자기완결 flag )* commit.
  arm1=combined bundle(-am/-ma), arm2=all→message(attached -mfoo/--message=foo
  포함), arm3=message→all. 위협 모델은 mistake-prevention (실수 방지) 으로
  명확화 — 적대적 따옴표 중첩 우회는 비목표.
- root cause: 이전 grammar 모델이 mistake-prevention 위협 표면에 과했고, 그
  복잡도에도 attached -mfoo 미포착 + quoted-message 처리 모호. 단순화로 정규식
  의도/한계를 명확히 하고 유지보수성 회복.
- 테스트: 적대적 따옴표 중첩 BLOCK 케이스 8개 (R2/R4 의 `-c "u=J K"` 등) 제거
  (비목표화), attached-value message 테스트 3개 + quoted-message over-block
  pin 테스트 1개 추가. 43/43 GREEN.
- 리뷰: codex Round 1 실행 (High 1건 — comment 가 quoted-message FP 를 "회귀
  아님" 으로 오기재) → 수정 (실측으로 NEW false-positive over-block 임을 확인,
  comment 정정 + test 를 assert_json_deny 로 pin). Round 2 codex usage-limit
  실패 → skill §4 sonnet fallback self-review (fallback_reason: codex_usage_limit).
- 수용 한계 (주석 기재): #1 따옴표 중첩 전역옵션 값 false-negative (비목표),
  #2 quoted 메시지 안 -a 토큰 false-positive over-block (보수적 차단, 수용).
- 전체 스위트: test-pre-bash-safety-guard 43 / test-codex-review-wrapper 33 /
  test-bash-guard-split 28 / test-pre-bash-test-commit-gate 14 /
  command-anchoring 28 — 전부 GREEN. bash -n OK.
- 교훈: 정규식 검증은 반드시 REAL command_invokes (bash-guard-infra.sh source)
  로 — 인라인 grep 재구성 probe 가 앵커링 차이로 잘못된 결과를 냈다. 실측 = 권위.
- 커밋: 미실행 (사용자 지시 대기, dev 누적).
