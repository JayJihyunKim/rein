# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1).

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **주입 규칙 언어 중립화 + 사용자 언어 추종 정책 (2026-05-29, dev 미커밋)**. 매 턴 주입되던 한국어 짧은 규칙 2개(`short/answer-only-summary`·`short/response-tone-summary`)가 영어 사용자 출력을 한국어로 soft-anchor 하던 결함. rein 에 "한국어로 답하라" 강제는 없음(codex Mode B R1 확인); 별개로 메인테이너 머신 `~/.claude/settings.json language:Korean` 은 하네스 하드 지시(이번 비대상). codex Mode B R2(gpt-5.5/high, Verdict C)가 "영어 한 줄 추가" 초안을 too-weak 기각 → 상시 한국어 닻(per-turn short summary) 자체를 영어 번역 + 출력 언어 정책(상위 시스템/하네스 지시 우선 → 사용자 요청 → 최신 메시지 주 언어, repo/규칙/trail 언어 추론 금지; settings.json 들여다보라 지시 안 함)을 톤 요약 맨 끝 + 전체 톤 규칙 신규 `## Output Language` 섹션에 추가. 전체본 한국어 유지(비용+메인테이너 선호). 제약 보존: short 크기(532B/1189B<한도), `## 행동 강령` 첫 헤더(mandate 1301B<2048). TDD red→green, 테스트 2개 갱신(마커 KR→EN + per-turn 정책 주입 positive + 한국어 닻 부재 negative). **전체 훅+스크립트 스위트 ALL PASSED, drift 검증 통과, codex Mode A PASS(차단0) + security standard 차단0**. 변경 파일 5: rules 3(short 2 + response-tone) + tests 2. **push 미실행(dev 누적, 사용자 승인 대기)**. 직전 완료 `16b56a6`(SR-1.b-MTIME-FP). 남은 active 후보: G3-perf-NFR / PLN-1+AG-2(보류) / public repo strip spot-check.
- **2026-05-28 회고 (v1.4.0 release 묶음)**: 오늘 5 cycle (communication-improve / worker contract + PLN1 enforce / AG-2 dogfood 4-worker / backlog 3-track cherry-pick / release prep) 의 dev 20 commits 통합. 사용자 결정으로 minor bump (Rule A advisory 따라). main 선별 체크아웃 = plugins/rein-core/** + tests/** + trail/** + 4 scripts/rein* + CHANGELOG (메인테이너 .claude/** + docs/** + 루트 임시 노트 제외). dev rotation 으로 archive 처리된 22 stale 파일 main 에서 동시 rm. 묶인 5 cycle 의 자세한 회고는 trail/inbox/2026-05-28-*.md.
- **직전 완료 (릴리스)**: **v1.4.0 (2026-05-28)** dev `c95efdf`/main `a474ea4`/tag `v1.4.0` push 성공. 응답 톤 강화 + 병렬 worker 메커니즘 + spec-review backstop + perf + rein update notice. 7 user-facing bullets. self-review R1 PASS + security light 면제. publish + mirror GH Actions 진행 중.
- **이전 릴리스**: v1.3.8(`bd3364b`/`c273add` plugin install hotfix+G3+TONE-1+자동모드, 2026-05-27), v1.3.7(`a50fb33`/`5f9791f` BC-INFO1 클래스 종결, 2026-05-24), v1.3.6(`698f38a`/`f76cf05` G8-3+job-stop+BC-INFO1), v1.3.5(`f7b3209`/`11a849e` SR-1+GE-1+GE-2), v1.3.4(`ad6b098`/`f01b7c9`), v1.0.0(2026-04-30 OSS launch). **현재 버전**: 1.4.0 main `a474ea4`/tag `v1.4.0`.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
