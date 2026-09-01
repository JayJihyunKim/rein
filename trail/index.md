# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **진행 중 (dev 로컬, push·배포 대기): persona 선택 UI 개선 + 표시 이름 현지화 (2026-08-28)** 최상위 3메뉴 재편 + 내장 3프리셋 표시 이름(마르코/제니/최행배) 도입 → 목록·turn-brief·세션시작 주입에서 영어 slug 노출 제거. dev 커밋 완료(설계+웨이브1/2+예산 hotfix), spec 5R user-approved·plan 5R PASS·웨이브1 코드/보안 PASS·전체 테스트 GREEN. push·배포등급 사용자 승인 대기. 상세 `trail/inbox/2026-08-28-persona-display-name-ui.md`.
- **직전 릴리스: v2.0.1 (2026-08-28, hotfix)** dev `36af892`/main `a698533`/tag `v2.0.1`/public `80efdb3`. **v2.0.0 설치 직후 전체 편집 차단 hotfix** — v2 가 편집 게이트 축을 기본 켜두었으나 그 축의 정책이 배포본에 미동봉 → 오버라이드 없는 사용자 프로젝트는 모든 편집이 복구 불가 차단(1.6.6 롤백 외 우회 불가). 수리: 정책을 배포본에 동봉(`plugins/rein-core/policies/task-axis/`) + 위임이 프로젝트 설정 → 배포 기본 순으로 해소(둘 다 없을 때만 차단, 위변조 가드 강화). 같은 날 hotfix 예외(critical 설치 장애). 재현 red→green·훅 배터리·플러그인 테스트 1650·실제 정책 e2e·main 트리 preflight 통과, 코드/보안 리뷰 PASS. 공개미러+마켓 발행 success(정책 public 도달·`docs/reports` strip 확인). 상세 `trail/inbox/2026-08-28-task-axis-bundled-policy.md`.
- **이전 릴리스: v2.0.0 (2026-08-27~28)** main `7adfa2f`/tag `v2.0.0`/public `f76cf5a`. **v2 governance 사용자 첫 배포(major)** — 통과 증거를 실제 검토 지문에 결속 + 게이트 권위를 자기 진술→신뢰 저장소로 이동. 08-07~27 dev Phase 0~7 전량이 main 첫 landing(plugins/rein-core 213파일). 상세: `trail/inbox/2026-08-28-release-v2-0-0.md`.
- **이전 릴리스 (상세는 각 inbox)**: v1.6.6(08-07 차단로그 봉합+자동 CI+publish preflight, main `b36a933`) / v1.6.3(07-23 페르소나+워치독, `9db782c`) / v1.6.2(07-22) / v1.6.1(07-13) / v1.6.0(07-10) / v1.5.8(06-26) / Releases 백필(07-03) / v1.0.0(04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
