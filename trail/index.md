# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 시작점 (2026-09-23)**: **두 사이클이 dev 에 통합됨(병합 `292cd16`, no-ff) — 릴리스 여부·등급은 사용자 결정 대기.** (1) 보안 통과 기록 발급 주체 이관(`feature/security` 8커밋: 체크포인트 `4547e79` / 설계 개정 `b9ff5d3`·`15ac2a5` / 웨이브 1 `d93ddad` / 웨이브 2 `2a8895a` / 종결 주석 `b347633` / 기록 `141c061`·`6bdd83a`): 지휘 경로 = 부모가 캡처→디스패치→확인→발급, 단독 호출 = 검토자 직접(이중 모드, dispatch 신호 일부만 있으면 UNRESOLVED). 프로덕션 파이썬·셸 변경 0, 테스트 2개 확장, 배포물: 에이전트 정의 2·규칙 2·스킬 1·AGENTS.md. 상세 `trail/inbox/2026-09-22-security-evidence-issuer.md`. (2) 리뷰 대기 시간 단축 1차(`7c1cd1e`, astra 자문 순위 1·2): 문서 지적 차단 기준을 두 봉투 공통 문단으로(결정·범위·사실 오류만 차단, 필수 보안 제약 누락은 계속 차단), 후속 회차 medium 조건부 기본값(High 잔존·(b)(c) 위반 → high 마커), 이벤트 로그 `effort`/`effort_source`, `.gitignore` 에 `.rein/state.lock`·`.omo/`. 리뷰 5회 83분 — **효과 미판정**(회차당 절감 0~40%, 표본 2; 사이클 전체는 운영 사고 2건으로 안 줄었음), 다음 5건의 로그로 판정. 상세 `trail/inbox/2026-09-22-review-cost-round1.md`. 병합 시 충돌은 `trail/incidents/blocks.jsonl` 하나(양쪽 append) — 줄 합치기로 해소. **릴리스 등급 판정 재료**: 두 사이클 모두 사용자 프로젝트의 skill/agent/rule 동작이 바뀌는 user-facing 새 동작(조건부 강도·부모 발급 절차) → Rule A 로는 minor 후보.
- 후속 후보(두 사이클): EFFORT 마커 첫 줄 단독 인정(요청서 본문의 마커 문자열을 래퍼가 마커로 오인 — 1회차 사고), 후속 회차 전용 봉투(자문 3순위, 설계 필요), 누적 시간 예산 + 사람 종결, 지문 수집이 미추적 파일을 넓게 포함하는 규칙(외부 도구 산출물에 취약 — 27분 통과 발급 거부 사고) + 사용자 `.gitignore` 템플릿의 `.rein/state.lock`, codex-ask 스킬 `--full-auto` 예시 정정(코덱스 0.155.1 거부), 셸 하니스 `Failed` 계수 의미, awk anchor 키 정규식(low), 계획 문서 "11개 검사" 서술 갱신, 2026-09-22 설계 §8(light 면제 죽은 문구·발급자 provenance·워커 결과 코드 파싱), 이벤트 테스트 `computed+floor`·직접 호출 null 단언, 스킬 79·359행 "High 잔존 vs 필수 축 미수행" 동시 참 우선순위, wallclock 설계 "8필드" 표기. 이전 후속(2026-09-10 설계 §8 항목 2~7, 사고 기록 집계 7종·파이썬 지문 17종·증거 manifest 4종 기기 실패, 회차 카운터 절대 경로 등)도 유지.
- **직전 릴리스: v2.1.3 (2026-09-22, patch)** main `e7082ce`/tag `v2.1.3`/public `a188642`, GitHub Release Latest. 메인 세션 지휘 기본화(설계 `docs/specs/2026-09-10-orchestrator-first-default.md`, 계획 `docs/plans/2026-09-21-orchestrator-first-default.md`) + 리뷰 소요 시간 기록 + awk 이스케이프 수리. 상세 `trail/inbox/2026-09-22-v2-1-3-release.md`.
- **이전 릴리스: v2.1.1 (2026-09-08~09, patch)** main `c14264e`/tag `v2.1.1`/public `0c73436` — 서브에이전트 stash 차단 + Bash 가드 절 시작 인식 확대 + 초기화 스크립트 수리. 상세 `trail/inbox/2026-09-08-v2-1-1-release.md`.
- **이전 릴리스: v2.1.0 (2026-09-07, minor)** main `90292f7`/tag `v2.1.0`/public `623af7d` — 리뷰 요청서 거부 규칙 + 주석 규칙 개정 + 문서-only 리뷰 조기 통과. 상세 `trail/inbox/2026-09-07-v2-1-0-release.md`.
- **이전 릴리스 (상세는 각 inbox)**: v2.0.3(09-04) / v2.0.2(09-01) / v2.0.1(08-28) / v2.0.0(08-27~28, v2 governance major) / v1.6.6(08-07) / v1.6.3(07-23) / v1.6.2(07-22) / v1.6.1(07-13) / v1.6.0(07-10) / v1.5.8(06-26) / v1.0.0(04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
- 코드 리뷰 요청서: 블록 밖에 "테스트+통과/PASS"·"N개 추가"·"실패/결함" 서술 금지(사전검사 exit 4). 본문에 `[EFFORT:…]` 문자열을 서술로 적지 말 것(래퍼가 본문 어디의 마커든 인식 — 첫 줄에만). 설계 문서 개정 시 표식이 풀려 소스 편집 즉시 차단 — 재검토·표식 후 편집. 리뷰 중에는 트리에 아무것도 쓰지 말 것(미추적 파일도 지문에 들어감 — 병렬 QA 도구 포함).
