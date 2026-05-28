# Worktree 일괄 cleanup — 17 branch + 11 folder 정리

- 날짜: 2026-05-28
- 유형: chore (운영 정리)
- 진행자: 본 세션 (claude direct)

## 결과

`.claude/worktrees/` 11 폴더 + git branch 17개 모두 제거. `git worktree list` = main dev tree (`81113b1`) 만 남음. `git branch --list 'worktree-agent-*'` empty.

## 정리 대상 분류

| 그룹 | 수 | 근거 |
|-----|---|-----|
| 본 cycle 3 트랙 (Track A=b82ddbf / B=d3620e5 / C=e924078) | 3 | dev push 된 cherry-pick (`b092f5a` / `c7f440d` / `ec7aff8`) 로 내용 보존 |
| v1.3.7 cycle (2026-05-23) — BC-INFO1 siblings/2/3 + A-LowPrio + spec-review-gate + job-stop | 5 | v1.3.7 release main `a50fb33` / tag / public 도달 |
| Hermes in-session 작업 (2026-05-26, Task 1.1 / 1.2 / 1.4 round-2) | 3 | 2026-05-26 PIVOT 으로 in-session subagent 모델 폐기 + 외부 CLI integration 으로 전환. 본 worktree 의 산출물은 폐기 아키텍처 |
| stale branches (worktree 이미 부재, branch 만 잔존) | 6 | git branch -D 시 추가 발견 — worktree-agent-{a17e395f / a182051d / a1fef1657 / a40077c3 / a4072e1 / a457717526}. `git worktree prune` 이전에 누락된 garbage |

## 진행 절차

1. `git worktree unlock <path>` × 11 (모두 locked)
2. `git worktree remove --force <path>` × 11
3. `git branch -D <branch>` × 17 (예상 11 + stale 6)
4. `git worktree prune -v`

각 단계 success — 명시 실패 없음.

## 운영성 주의

zsh sub-shell PATH 가 깨져 git/sed/head 가 not-found 로 첫 시도 실패. `/usr/bin/git` 절대경로로 재시도 후 성공. while-loop in pipeline 안의 PATH 환경 격리 issue — 추후 cleanup script 작성 시 `command -v git` 또는 절대경로 고정 권장.

## 후속

- 추가 cleanup 자동화: `WorktreeCreate` / `WorktreeRemove` hook 이 matcher 미지원이라 agent-specific 자동화 불가. 본 manual cleanup 패턴이 worktree-cleanup.md 의 5-step 절차로 유지 (PLN-1+AG-2 cycle 의 의도된 제약).
- PLN1-GATE-ENFORCEMENT 활성화 (별도 DoD)
- main 머지 + release (별도 DoD)
