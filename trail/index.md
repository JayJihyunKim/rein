# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **직전 릴리스: v1.6.5 (2026-08-05)** dev `d923bde`/main `0f191e1`/tag `v1.6.5` push+publish+mirror success (public plugin.json 1.6.5, 내부기록 404, public tag clean `cd76183`, Release Latest). 번들: 리뷰 회차 예산(상한 5·연장 가시화·문서 리뷰 전용 판정·카운터 하드닝) + 게이트 판정 범위 결함 3건(표식 저장소 경계·무관 문서 경고 강등·heredoc/샌드박스 커밋 구분+워크트리 판별). 기계판정 minor→**사용자 결정 patch**. 리뷰: 코드 codex 2R+sonnet 대체 2R(codex 한도 8/10 복구)+릴리스 델타 PASS, 보안 3회 PASS, 역변이 검증 4종. 상세: `trail/inbox/2026-08-05-release-v165.md`.
- **완료 상세 (v1.6.5 번들 2사이클)**: ①리뷰 회차 예산(`76e4c67`) — 코드 1차 5R+2차 5R PASS, 보안 2회 PASS. 상세는 daily/weekly 회전분. ②게이트 판정 범위 결함 3건(`2ad12a5`) — 보안 지적 1건(워크트리) 수리 포함. 상세: `trail/inbox/2026-08-05-gate-scope-defects.md`.
- **완료 (2026-08-07, dev `3e1213a`)**: v1 안전 소릴리스 사이클 — 차단 로그 민감정보 봉합(마스킹 SSOT+비추적 분리+test 태깅 집계 제외) + 전 스위트 자동 CI(dev push/PR, 7스위트) + publish preflight 연결 + 기존 실패 2건 수리(통합 fixture·routing-map 770B). 리뷰: sonnet 대체 3R PASS(codex 한도 8/10 복구)+보안 PASS(Medium 1 즉시 반영). **버전 승격·main·태그·push 는 사용자 승인 대기**. 상세: `trail/inbox/2026-08-07-v1-safety-prerelease.md`.
- **다음 작업 (사용자 확정, 2026-08-07 갱신)**: ①안전 소릴리스 릴리스 실행(patch 후보, 승인 대기) ②Rein v2 설계 정식화 — 사용자 v2 설계 문서(Governance Runtime + Prompt-Driven Orchestration, 오케스트레이터는 B안=중첩 디스패치+버전 감지 강등) 를 입력으로 브레인스톰→스펙 절차. 이전 확정 2건(연쇄 드리프트 재설계·산출물 경로 재배치)은 v2 범위로 흡수. 상세: `trail/weekly/2026-W31.md`.
- **이전 릴리스: v1.6.3 (2026-07-23)** dev `54bb1bb`/main `9db782c`/tag `v1.6.3` push+publish+mirror success (public plugin.json 1.6.3 도착, 내부기록 404 strip, public tag clean `4fbda74`). 번들: 페르소나 사용자 선택+커스텀·변경 인사말·대화 언어 적응(영어권)·전환 메타금지 + codex 리뷰 시간상한 워치독. 기계판정 minor→**사용자 결정 patch**. 릴리스 번들 리뷰 sonnet 대체 PASS(codex 워치독 timeout)+보안(문서/버전-only). 후속 Low: 닫는 fence·greeting L4필터·Scope ID·`tests/agents` routing-map 875B. 상세: `trail/inbox/2026-07-23-release-v163.md`.
- **이전 릴리스 (상세는 각 작업 기록)**: v1.6.2(2026-07-22, 리뷰 사이클 효율화 — 자가검증 관문+출력축소, main `a7062b0`) / v1.6.1(2026-07-13, 리뷰 증거 블록 필수+index 줄수 게이트+trail 위생, main `c5f5c88`) / v1.6.0(2026-07-10, codex 모델 프로필 라우팅, main `b815f85`). 각 후속 Low 는 해당 inbox 참조.
- **이전 완료·구 릴리스 (상세는 daily/weekly 회전분·각 inbox)**: v1.5.8(06-26 effort 결정론 산출) / GitHub Releases 백필 31개(07-03) / v1.5.x 시리즈(06-09~06-18: 페르소나 프리셋, truncation·오탐·게이트 FN 봉합, 마커 감사, 커밋 보안 면제, helper 경로 정정) / v1.0.0(2026-04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
