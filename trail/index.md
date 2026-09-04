# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 작업 — 2026-09-04 v2.0.3 배포 진행 중**: ①(보안 축, `54b1377`) ②-A(`4430959`) ②-B(`aafbc9c`) + `.rein/state.json` 무시 규칙(`ab55438`) + **세션 시작 훅 리눅스 POSIX 모드 셸 종료·표식 삭제 실패 무음 수리(`6ece5d1`, dev CI 실패 + main 통합 리뷰 High 계기, 상세 `trail/inbox/2026-09-04-session-start-stuck-marker-complete.md`)** 를 묶어 **patch v2.0.3** 배포 사이클(`trail/dod/dod-2026-09-04-v2-0-3-release.md`): dev 배포 표면 커밋·푸시 완료(`51ed7b1`,`94a476b`) → main 격리 트리 선별 반영·preflight → 통합 리뷰(4회차까지 지적 반영, 5회차 예정) → tag → 미러·마켓 발행 검증. 그 다음 ③ 리뷰 자기증폭 봉합. 후속 Low: 루트 `scripts/rein.sh` 의 `: > file` 1곳, 비 UTF-8 .gitignore traceback.
- **직전 릴리스: v2.0.2 (2026-09-01, patch)** dev `2326dc6`/main `34520bc`/tag `v2.0.2`/public `8f7b5cd`. **persona 선택 UI 개선 + 표시 이름 현지화** — 최상위 3메뉴(목록/만들기/끄기) 재편 + 내장 3프리셋 표시 이름(마르코/제니/최행배, 영어 표기는 마르코·제니만) 도입, 목록·turn-brief·세션시작 주입의 영어 slug 노출 제거. main 트리 preflight 전량 GREEN, main 스테이징 codex 리뷰에서 문서 서술 과장·날짜·DoD 목록 지적 → dev 정정(`2f11561`,`2326dc6`) 후 PASS·증거 발급. 공개미러+마켓 발행 success, 공개 트리 strip·도달 실측. 함정 2건(리뷰 중 세션 캐시 churn 으로 지문 불일치 1회, main 체크아웃 중 trail 재회전 잔여물) 기록. 상세 `trail/inbox/2026-08-28-persona-display-name-ui.md`.
- **이전 릴리스: v2.0.1 (2026-08-28, hotfix)** main `a698533`/tag `v2.0.1`/public `80efdb3`. **v2.0.0 설치 직후 전체 편집 차단 hotfix** — 편집 게이트 축 정책이 배포본에 미동봉 → 정책 동봉 + 프로젝트 설정→배포 기본 2단 해소. 상세 `trail/inbox/2026-08-28-task-axis-bundled-policy.md`.
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
