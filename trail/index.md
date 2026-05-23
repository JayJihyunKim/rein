# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **다음 작업 = 잔여 백로그 (G3 feature 재검토 / A-LowPrio 테스트 / SR-1.b low / BC-INFO1-siblings low)**. ⚠️ "다음 작업 = v1.5" 는 **폐기** (2026-05-23 로드맵 평가: v1.5 No-Go / v1.6 Defer / v1.7 이미 구현). 근거 = `docs/brainstorms/2026-05-23-v15-17-roadmap-evaluation.md` + `feedback_felt_value_before_roadmap_work`. 상세 = `need-to-confirm.md`.
- **직전 완료 (dev, 미push)**: **실제 버그 3건 병렬 처리 (2026-05-23)** — worktree 격리 agent teams. G8-3(spec-review 무관 active-DoD Tier-2 fallback 차단) / job-stop(`cmd_job_stop` 종료상태 기록 + compare-and-set 가드) / BC-INFO1(bootstrap-check cold-path git env sanitize). 통합 codex R1 NEEDS-FIX(job double-settle race)→R2 PASS, security 0 차단(INFO: sibling libs 동일패턴=BC-INFO1-siblings 후속). 전체 테스트 GREEN. dev 3 commit, origin/dev 미push.
- **직전 완료 (릴리스)**: **v1.3.5 배포 완료 (2026-05-22) — 검증 통과**. SR-1+GE-1+GE-2 patch 릴리스. main = origin/main = `f7b3209`, annotated tag `v1.3.5`. publish-plugin(marketplace) + mirror-to-public ×2 모두 GH Actions success. public mirror main=tag=`11a849e`(strip commit — tag 가 strip 커밋 가리킴 확인). housekeeping: 잔존 `.rein/policy/router/*.yaml` git rm. Rule B same-day override(사용자 지시, 핫픽스 아님).
- **이전 완료 (dev)**: **GE-1+GE-2 (dev `046bac4`)** — wrapper/selector 무결성. GE-1: selector Tier 1 marker path containment(공용 `path-containment.sh` → selector+session-start 공유, helper 부재 fail-closed) / GE-2: `_resolve_diff_base` 가 fresh stamp diff_base 를 `rev-parse ^{commit}` + `merge-base --is-ancestor` 검증(forged/orphan/other-branch→HEAD~1). codex PASS + security 0 findings. / **SR-1 (dev `9f2ff18`)** — spec-review gate stale `.reviewed` 2겹 차단. 27/27, codex R3 PASS, security PASS. 잔존 SR-1.b(low). 셋 다 confirmed.md.
- **이전 완료 (릴리스)**: **v1.3.4 (2026-05-22)** main `ad6b098`, tag `v1.3.4`, public `f01b7c9`.
- **이전 완료**: 2026-05-22 **v1.3.4 구현** (B1/B2/B3/B6/B7+S+D). / 2026-05-22 X4.C.5 atomic state fast-path (영역 C close). / 2026-05-22 영역 D 기각. / 2026-05-20 **v1.3.3 릴리즈** (main `0f7e3ef`, tag `a4995c3`). / 2026-04-30 v1.0.0 OSS launch.
- **버전**: plugin.json = scripts/rein.sh VERSION = **1.3.5** (parity OK). main = origin/main = `f7b3209`, annotated tag `v1.3.5` → `f7b3209`. public mirror main=tag=`11a849e`(strip commit). v1.3.5 = patch (SR-1+GE-1+GE-2 게이트 hardening).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
