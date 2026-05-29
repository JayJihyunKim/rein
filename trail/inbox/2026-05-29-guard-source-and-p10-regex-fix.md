# 가드 버그 2건 수정 — wrapper source fail-closed + P10 정규식 오탐

- 날짜: 2026-05-29
- 유형: fix
- 변경 파일:
  - plugins/rein-core/hooks/pre-bash-safety-guard.sh (P10 정규식 재작성)
  - plugins/rein-core/scripts/rein-codex-review.sh (라이브러리 source fail-closed)
  - scripts/rein-codex-review.sh (dev-fallback 사본, byte-identical)
  - tests/hooks/test-pre-bash-safety-guard.sh (P10 회귀 테스트 다수)
  - tests/skills/test-codex-review-wrapper.sh (fail-closed 회귀 4건)
- 요약: need-to-confirm.md 버그 리포트 2건을 codex Mode B 로 검증 후 수정.
  - **버그1 (wrapper fail-closed)**: 의존 라이브러리 없을 때 `set -e` 하 `source` 실패가 then 블록 도달 전 종료시켜 조용한 exit 1 내던 것을 `[ ! -r ]` precheck + 서브셸 검증으로 ERROR+exit 2 fail-close. (리포트의 "POSIX 특수빌트인" 근본원인 설명은 codex 가 부정확으로 정정 — 실제는 errexit×source 상호작용.)
  - **버그2 (P10 정규식)**: `.env` 존재 시 실수 `git commit -am` 차단 가드. `--amend`/텍스트 언급 오탐 + 전역옵션/`-mfoo`/attached-quote 미차단을 command_invokes 기반 단순 3-arm 정규식으로 교체. mistake-prevention 위협모델로 범위 확정 (적대적 따옴표 중첩은 비목표).

## 진행 경과 (긴 리뷰 사이클)
- codex Mode B 가 두 버그 검증 + 제안 정규식 결함 발견.
- 구현 중 SR-1.b cherry-pick mtime 오탐으로 spec 게이트가 25개 무관 문서를 연쇄 차단 → 전체 스캔(내용 불변 25건 확인, 진짜 재검토 0건) 후 사용자 승인 하에 일괄 회고적 갱신으로 해소.
- codex 통합 리뷰 R1/R2: global-opts false-negative + proportionality(over-engineering) 지적 → 사용자 승인 하에 SIMPLIFY.
- codex usage-limit(5/31) → §4 Sonnet fallback: 독립 코드품질(general-purpose) PASS + 보안(security-reviewer) MEDIUM(attached-quote 회귀) 발견 → 수정 → 재확인 PASS.

## 검증
- test-pre-bash-safety-guard 48/48, test-codex-review-wrapper 33/33, test-bash-guard-split 28/28, command-anchoring 28/28, test-pre-bash-test-commit-gate 14/14. bash -n 통과.
- 두 사본 byte-identical (cmp).

## 수용 한계 (주석 명시, 비목표)
1. 적대적 따옴표 중첩 전역옵션 값(`git -c "u=J K" commit -am`) 미차단 — 작정한 우회, mistake-prevention 범위 밖.
2. 따옴표 메시지 안 standalone `-a` over-block(`git commit -m "use -a flag"`) — command_invokes 따옴표 비인식 한계.

## 커밋 상태
- dev 미커밋 (사용자 지시 대기). 리뷰 표식 2종(코드: sonnet-fallback / 보안) 생성 완료.
