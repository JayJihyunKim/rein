# DoD — 게이트 false-negative (misfire) 4건 수리

- 날짜: 2026-06-12
- plan ref: docs/plans/2026-06-12-gate-misfire-fixes.md

## 배경 / 동기

정직한 에이전트가 우회를 의도하지 않아도 rein 게이트가 조용히 미발동(false-negative)하는 구멍 4건. 신뢰가 rein의 존재이유이므로, 게이트가 새는 줄 모르고 "리뷰 거쳤겠지" 믿는 거짓 안심을 봉합한다. 위협모델은 "정직한 에이전트 규율"까지로 확정(적대적 우회 하드닝은 범위 밖 — spec §제외).

## 범위

- **GMF-1**: canonical "git commit" 탐지 패턴을 공유 lib(`lib/git-subcommand-model.sh` 신설)로 단일 정의(SSOT)하고 분류기·dispatcher·게이트 내부 `command_invokes` 세 곳에 적용. 다중 공백 + git 글로벌 옵션 allowlist(`-C`/`-c`/`--git-dir` 등) + shell-token 경계로 과매칭 방지. (`git -C . commit`/더블스페이스/`-c k=v` 형태가 더 이상 게이트를 빠져나가지 않음)
- **GMF-2**: merge/rebase/am 면제를 비앵커 substring → 실제 subcommand 파싱으로 교체. 진짜 merge/rebase/am만 면제 유지, 커밋 메시지에 "git merge" 든 일반 커밋의 오매칭 제거.
- **GMF-3**: DoD 소스 판정을 디렉토리 화이트리스트 + 소스 확장자 화이트리스트(additive) + 비소스 제외로 확장. 즉시강제(기본 ON), 첫 차단 시 파일당 1회 안내. tightening-only(기존 차단 불완화).
- **GMF-4**: 3개 게이트의 정책 토글 fail-open 봉합. resolver 사용 + 로더 호출실패(인터프리터 부재)는 fail-closed(게이트 활성), 로더 정상 exit 1(비활성)과 구분.

제외: 적대적/인젝션 에이전트의 의도적 우회 하드닝(정책 kill-switch 보호, 도장 content_sha 바인딩, 스탬프 위조 방지) — 위협모델 밖.

## 변경 파일

- `plugins/rein-core/hooks/lib/git-subcommand-model.sh` (신설 — canonical 토큰 모델 SSOT)
- `plugins/rein-core/hooks/lib/bash-classifier.sh`
- `plugins/rein-core/hooks/pre-bash-dispatcher.sh`
- `plugins/rein-core/hooks/pre-bash-test-commit-gate.sh`
- `plugins/rein-core/hooks/pre-edit-dod-gate.sh`
- `plugins/rein-core/hooks/pre-bash-safety-guard.sh`
- 테스트: `tests/hooks/test-bash-dispatcher.sh`, `test-pre-bash-test-commit-gate.sh`, `test-bash-guard-split-command-anchoring.sh`, `test-pre-edit-dod-gate.sh`, `test-pre-bash-safety-guard.sh`

## 검증 기준

- TDD red 우선: 각 false-negative 재현 케이스를 실패 테스트로 먼저 고정 (`git -C . commit`/더블스페이스/메시지에 `git merge` 든 일반 커밋/`internal/x.go` 편집/python3 부재 시뮬).
- 회귀 방지: 정상 `git commit -m` 발동 유지, dev no-ff 머지 면제 유지, 문서·데이터·lockfile 편집 통과, `git commit-graph write`/`git config commit.gpgsign` 과매칭 0, python3 정상 시 정책토글 동작.
- behavioral-contract(GMF-3 tightening-only / GMF-4 fail-open→fail-closed)는 방향+임계값을 scenario 실행 결과로 검증.
- 세 테스트 스위트(hooks/scripts + 신규 케이스) green. 통합 codex 리뷰 + 보안 리뷰 PASS.

## 라우팅 추천

agent: rein:parallel-execute (plan 실행 전략 — Wave 1 [GMF-1 ‖ GMF-3] 병렬 edit_only → Wave 2 [GMF-2, gmf1 의존] → Wave 3 [GMF-4, gmf2·gmf3 의존], 각 worker = rein:feature-builder-fix)
skills:
  - rein:codex-review
mcps: []
security_tier: standard
complexity: medium
model_hint: opus
effort_hint: medium
rationale:
  - 게이트 강제력 정합 수정 — 보안 경계(커밋/편집 게이트) 직접 변경이라 security_tier standard, 통합 보안 리뷰 필수
  - plan 이 파일 공유 의존 위상(Wave 3개)으로 설계됨 → parallel-execute 로 Wave 단위 dispatch, 부모가 웨이브별 검증·테스트·커밋
  - 버그 수정 성격(false-negative 봉합) + 재현 테스트 선행 → worker = feature-builder-fix
  - 6개 hook 파일 + 신설 공유 lib, 기존 패턴 재사용 → complexity medium
approved_by_user: true
