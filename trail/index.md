# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **마커 감사 백로그 M1~M4 + 세션 후속까지 전부 완료 (2026-06-16, dev 누적·미release)** — 상세 `trail/daily/2026-06-15.md`. M1=`.skip-spec-gate` 1회 소비, M2/M3/M4=리뷰 통과 표식 신선도+내용 dual-read + 생성기 fail-open 봉합(DoD `dod-2026-06-16-review-stamp-freshness.md`), 세션 후속=커버리지 검증기 표 형식 leniency(번호 heading+백틱 ID, silent-skip 재발 봉합) + M4 바이패스 삭제증명·echo sanitize(DoD `dod-2026-06-16-session-followups.md`). 전부 codex+보안 PASS, 자기 게이트 dogfood 통과. **다음 후보**: (a) **릴리스 판단** — M1~M4+후속 묶어(hook/validator 동작변경=user-facing → patch/minor, Rule A/B; 어제 v1.5.4 머지라 하루 1머지 규칙 확인), (b) A1/E2 문서 정정, (c) ⓑ CI 자동 테스트 0건, (d) routing reason echo sanitize(비범위였음). 위협모델 밖 보류: 도장 원자성·blocks.jsonl 락(D1/D2).
- **직전 완료 (릴리스)**: **v1.5.4 (2026-06-15)** dev `718226a`/main `f6f6b6c`/tag `v1.5.4` push + publish + mirror success (public: plugin.json 1.5.4 도착, trail/AGENTS.md/.rein 404 strip 검증, public tag clean commit `e21607a`). 외부 사용자 제보 → codex-ask 독립 검증 발: ① 자동모드 스킬 안내 정정(자동모드는 incident 블록만 silent, inbox/index 작업증거 종료차단은 자동모드여도 발동 — 버그 아닌 문서 과장) ② 메타체크 방치-untracked false-positive 수정(untracked 를 비교집합 합치기 전 세션시작 mtime-window 필터 + fail-open, 재현 F14/F15/F16). 코드+보안 리뷰 PASS, 메타체크 16 green. **patch** (hook 동작변경=user-facing 버그수정, Rule A).
- **이전 릴리스 (직전)**: **v1.5.3 (2026-06-12)** main `079c616`/tag `v1.5.3` — 게이트 false-negative 4건 봉합(커밋탐지 SSOT화 + 머지 면제 오매칭 제거 + 소스판정 확장자 + 정책 fail-closed).
- **이전 릴리스**: v1.5.2(`c8dba3b` 리뷰 오탐 감소 + marker 오삭제 근본원인 + SIGPIPE fail-open, 06-11), v1.5.1(`e470def` 페르소나/규칙 주입 truncation 수정, 06-11), v1.5.0(`a7752e7` 페르소나 프리셋 + wrapper 결함 6건, 06-09), v1.4.7(`dbcfc8d` codex gpt-5.5 통일), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷), v1.0.0(2026-04-30 OSS launch). 2026-05-28 v1.4.0 회고는 trail/inbox/2026-05-28-*.md.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
