# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **helper 스크립트 호출 경로 플러그인-루트 고정 — dev 편집·검증 완료, 미커밋(codex 리뷰+커밋 대기)**. ship 문서 5개(`skills/codex-review`·`skills/code-reviewer`·`rules/subagent-review`·`agents/spec-writer`·`agents/plan-writer`)의 `bash scripts/rein-*.sh` 호출 12곳을 `bash "${CLAUDE_PLUGIN_ROOT:-$PWD}/scripts/rein-*.sh"` 로 정정(플러그인 우선+repo 폴백, RES-1 우선순위 일치). 진단: bare 상대경로라 repo 루트 복제본(dogfood 전용)에 떨어져 정본 캐시와 드리프트 위험·사용자 repo 엔 부재. DoD `dod-2026-06-18-skill-invocation-plugin-root`, inbox 동명. .sh 자체 `# Usage:` 주석 6줄은 비범위(내부 설명). 다음: codex 리뷰→dev 커밋(릴리스 타이밍 보스 결정). 비범위 후속: repo 루트 `scripts/` 복제 동기화 강제.
- **이전 진입점 후보 (v1.5.6 배포 후)**: (a) A1/E2 문서 한 줄 정정, (b) CI 자동테스트 0건(workflow_dispatch만 + 러너 미등록), (c) routing 블록 reason echo sanitize(M4 동일 패턴). audit 로그 churn 해결: `security-surface-exempt.log` gitignore+추적제외 `262083c`(dev only — .gitignore 는 main-include 라 다음 릴리스 main checkout 때 동기화 권장). 위협모델 밖 보류: 도장 원자성·blocks.jsonl 락(D1/D2).
- **직전 완료 (릴리스)**: **v1.5.6 (2026-06-17)** dev `c07deb1`+/main `0777835`/tag `v1.5.6` push + publish + mirror success (public: plugin.json 1.5.6 도착, trail/AGENTS.md/.rein 404 strip 검증, public tag clean commit `d59c5134`). **commit-gate 보안-surface 면제**: 문서(`*.md`/`docs`/`trail`)·버전문자열-only(`rein.sh` VERSION 라인/`plugin.json` top-level version semantic JSON) 커밋이면 보안 재검토(P6+M2) 자동 면제 → v1.5.5 M2 릴리스 마찰 근본 해결. 명령형태 = **단일-clause 종착 규칙**(전경 단독 `git commit <allowlist>` 만; multi-clause/wrapper/cd/env/글로벌옵션/쉘평가/서브셸/백그라운드 `&` → 전부 fail-closed). 명시 허용목록 외 전부 보안 관련=fail-closed. brainstorm→spec→plan(codex PASS)→구현→통합 codex 4R(R2 비-git clause skip·R3 백그라운드 봉합)+보안 PASS. 테스트 104+15 GREEN. ✅ **dogfood 실증**: v1.5.6 버전범프 커밋(`fac2000`)이 단독 `git commit` 으로 면제 발동(audit `staged_files=5 docs=3 version=2`). ⚠️ **정정**: 활성 게이트는 캐시(1.5.4)가 아니라 **워킹트리 훅**(M2·면제 라이브). 앞서 실커밋 면제 미발동은 `cd …; git commit`(다중 clause) 때문 — [[reference_plugin_directory_marketplace_lifecycle]]. **patch** (hook 동작변경=user-facing, Rule A).
- **이전 릴리스 (직전)**: **v1.5.5 (2026-06-16)** dev `fd61010`/main `ff05a3d`/tag `v1.5.5` (public tag clean `60e7a1e`). 마커 감사 백로그(M1~M4) 봉합 — M2 보안표식 신선도/cycle/verdict + M3 코드표식 dual-read 등.
- **이전 릴리스**: v1.5.4(`f6f6b6c` 자동모드 안내 정정 + 메타체크 거짓경고 제거, 06-15), v1.5.3(`079c616` 게이트 false-negative 4건 봉합, 06-12), v1.5.2(`c8dba3b` 리뷰 오탐 감소 + marker 오삭제 근본원인, 06-11), v1.5.1(`e470def` 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋, 06-09), v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
