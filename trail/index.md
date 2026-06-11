# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **다음 세션 진입점**: **활성 백로그 0건** — 2026-06-09 후속 2건 모두 종결 (① envelope 슬롯 일관성: 전면 재설계 기각 → 경계 정합 + 근본원인 + SIGPIPE fail-open 수정, 기록 `trail/inbox/2026-06-11-envelope-subject-consistency.md`. ② perf3·json-parity: 삭제 종결, 기록 `trail/inbox/2026-06-11-delete-stale-orphan-tests.md`). 검토 후보: skills 러너 CI 미등록 (2026-06-11 하루에 같은 클래스 잠복 2회 발견).
- **직전 완료 (릴리스)**: **v1.5.2 (2026-06-11)** — 리뷰 오탐 감소(Tier 추측 컨텍스트 advisory 정직화 A1~A5) + marker 오삭제 근본원인 C1 + SIGPIPE fail-open 2건(D1 fail-soft 가드 / D2 모드감지 — 코드게이트 오염 가능성) 봉합. dev `ee68f4f`+release prep. TDD red 선행 11건, wrapper 54/54, 세 스위트 green, codex 3R(R2 가 D2 적발)+보안 PASS. **patch** — 같은날 v1.5.1 후 추가 배포는 게이트 무결성 hotfix 명분 + 사용자 결정 (Rule B override, hotfix for v1.5.1). main/tag/publish 검증값은 git 스냅샷·원격 재검증 우선.
- **이전 릴리스**: v1.5.1(`e470def` 페르소나/규칙 주입 truncation 수정 — per-hook cap 초과로 페르소나 미도달, 2026-06-11), v1.5.0(`a7752e7` 페르소나 프리셋 신규 + wrapper 결함 6건, 2026-06-09), v1.4.7(`dbcfc8d` codex 모델 gpt-5.5 통일, 2026-06-09), v1.4.6(`521ab6a` 모델 단일 출처+fail-soft, 2026-06-08), v1.4.5(`70ef345` 첫세션 온보딩+git 스냅샷, 2026-06-05), v1.0.0(2026-04-30 OSS launch). 2026-05-28 v1.4.0 묶음 회고는 trail/inbox/2026-05-28-*.md.

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
