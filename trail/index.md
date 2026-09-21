# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 시작점 (2026-09-21)**: **메인 세션 지휘 기본화 — 구현 완료(dev 커밋 4개: `57837de` 워커 리뷰 이관 예외 / `7033d2c` 규칙 쌍·플래그 읽기·교차 참조·지휘자 에이전트 재정의 / `40b65e4` 세션 시작 배선 + 이 저장소에서 기능 켬 / 마지막 = 8월 잠긴 설계 문서 §2.5 대체 주석). 설계 범위 항목 15개 전부 구현, 저장소별 opt-in·기본 비활성, 배포본 기본값 불변. 이 저장소는 켜져 있어 다음 세션 시작부터 지휘 규칙 요약이 주입된다.** 설계 `docs/specs/2026-09-10-orchestrator-first-default.md`(§3.6 괄호 참조 한 곳 정정·재검토 통과), 계획 `docs/plans/2026-09-21-orchestrator-first-default.md`. 전체 요약·리뷰 이력 `trail/inbox/2026-09-21-orchestrator-first-lock-supersede.md`. **미결(사용자 결정): 보안 통과 기록의 발급 주체 모순(워커 금지목록 vs 보안 리뷰어 정의) — 설계가 분리해 둔 후속, 이번엔 기존 절차(검토자 직접 발급)대로 진행.** 릴리스 여부·등급은 미정(사용자 프로젝트에는 기본 비활성이지만 규칙 파일·로더 CLI·작업 기록 형식 필드가 배포물에 들어간다 — 버전 규칙으로 판정 필요). 운영 교훈: 보안 검토 전에 스테이징(보안 지문은 스테이징분만 봄), 완료 기록은 맨 끝에(미리 쓰면 편집 게이트가 작업을 끝난 것으로 봄), 문서만 바뀐 단위는 코드 리뷰 지문 대상이 없음, 설계·계획 문서는 편집 도구로만 고칠 것. 후속 후보: 이 기기에서 떨어지는 사고 기록 집계 7종·파이썬 지문 계산 17종·스킬 2종(CI 미확인), 규칙 요약 주입 테스트 1종(페르소나 요약 상한, run-all 미등록), 빈 런타임 잠금 파일이 코드 리뷰 지문에 들어감, 래퍼가 넘기는 변경 목록에 신규 미추적 파일 누락, 커밋 제목에 "회" 글자가 들면 오거부하는 훅 결함, legacy plan 4개, 래퍼 쪽 항목(문서 내부 충돌 분류 칸, 회차 카운터의 절대 경로 의존).
- 이 설계에서 분리해 둔 후속 후보(문서 §8): 보안 증거 발급 모순, 실물 없는 리뷰 담당자 참조, 규칙 4곳의 낡은 훅 이름, 설정 안내 주석 불일치, 낡은 보안 등급 서술, 조사·문서·설계로의 확대. 이전 잔여 후보(정규식 분류기 파서급 한계, 미러 strip 목록)도 유지.
- **직전 릴리스: v2.1.1 (2026-09-08~09, patch)** dev `a976194`·`8cfbaf4`/main `c14264e`/tag `v2.1.1`/public `0c73436`. **서브에이전트 `git stash` 구조적 차단[P12] + Bash 가드 절 시작 인식 확대(`{ )` 백틱·예약어, 분류기 공유 규칙 4종) + 초기화 스크립트 비 UTF-8 `.gitignore` 보존·`project.json` 디렉터리 거부** — 코드 `f74eca2`(codex 4회차 후 사용자 승인 종결), 릴리스 커밋 codex 2회차 PASS(1회차 High: rein job start 주장 상충 → 항목 삭제), main 격리 트리 preflight 4종+통합 리뷰 2회차 PASS, 미러·마켓 발행 success, GitHub Release Latest, main 전용 정리 `94f2441`. 등급 근거: Rule A 사용자 승인 예외 + 결함 수정 묶음. 상세 `trail/inbox/2026-09-08-v2-1-1-release.md`.
- **이전 릴리스: v2.1.0 (2026-09-07, minor)** dev `3e4a826`/main `90292f7`/tag `v2.1.0`/public `623af7d`. **리뷰 요청서 거부 규칙(블록 밖 실행 결과 서술 exit 4) + 주석 규칙 개정(지속 계약만) + 문서-only 리뷰 조기 통과(관측 일관성) + CLI `changeset_paths`** — 구현 `2c775ae`·`7b7c249`(웨이브마다 codex+보안 PASS), 릴리스 커밋 codex 5회차(마지막 Medium 1 은 3줄 이하 자체 검토 종결), main 격리 트리 preflight 4종+통합 리뷰 PASS, 미러·마켓 발행 success, **GitHub Release Latest(신규 절차 첫 적용)**. 등급 근거: Rule A 사용자 승인 예외 명문화. 상세 `trail/inbox/2026-09-07-v2-1-0-release.md`.
- **이전 릴리스: v2.0.3 (2026-09-04, patch)** dev `384cc4d`/main `e5049c4`/tag `v2.0.3`/public `5e7033a`. 보안 검토 축 복구 + 세션 종료 훅 잔여물 + git 필수 온보딩 안내 통일 + 런타임 상태 파일 무시 규칙 + 세션 시작 훅 리눅스 POSIX 모드 수리. 상세 `trail/inbox/2026-09-04-release-v2-0-3.md`.
- **이전 릴리스: v2.0.0 (2026-08-27~28)** main `7adfa2f`/tag `v2.0.0`/public `f76cf5a`. **v2 governance 사용자 첫 배포(major)** — 통과 증거를 실제 검토 지문에 결속 + 게이트 권위를 자기 진술→신뢰 저장소로 이동. 08-07~27 dev Phase 0~7 전량이 main 첫 landing(plugins/rein-core 213파일). 상세: `trail/inbox/2026-08-28-release-v2-0-0.md`.
- **이전 릴리스 (상세는 각 inbox)**: v2.0.2(09-01 persona 선택 UI, main `34520bc`) / v2.0.1(08-28 hotfix 편집 차단 해소, `a698533`) / v1.6.6(08-07 차단로그 봉합+자동 CI+publish preflight, main `b36a933`) / v1.6.3(07-23 페르소나+워치독, `9db782c`) / v1.6.2(07-22) / v1.6.1(07-13) / v1.6.0(07-10) / v1.5.8(06-26) / Releases 백필(07-03) / v1.0.0(04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
