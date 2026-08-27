# trail/index.md — 현재 프로젝트 상태

> 5~25줄 유지 (`stop-session-gate.sh` 강제). **비권위 캐시** — release/git/branch/tag/publish claim 은 답변 전 git 명령 재검증 필수 (`.claude/rules/answer-only-mode.md` §3.1). git/릴리스 객관 수치(미push 수·dirty·태그 등)는 **손으로 쓰지 말 것** — 자동 스냅샷(`.rein/state/git-snapshot.md`)이 권위본.

## 현재 상태

- **프로젝트**: Rein (AI Native Development Framework)
- **직전 릴리스: v1.6.6 (2026-08-07)** dev `a754061`/main `b36a933`/tag `v1.6.6` publish+mirror success (public clean `aca4535`, Release Latest). 번들: 차단 로그 민감정보 봉합 + 전 스위트 자동 CI + publish preflight(첫 실전 — 결함 배포 3회 차단). 상세: `trail/inbox/2026-08-07-release-v166.md`+`2026-08-07-v1-safety-prerelease.md`.
- **완료 (08-07~19): v2 설계~Phase 6 전량** — 설계 정식화(spec 42 Scope·45태스크) + Phase 0~5(kernel·evaluator·adapter·마스킹 SSOT·증거 Runtime 발급·위조 차단·요구 5종 이관·기본 정책·orchestration 5모듈) + Phase 6(capability 5종 실배선·authority 전환 계층·정책 버전 SSOT·겸업 훅 분리[1247→578줄]·옛 테스트 218건 분류) + Phase 6 종결(2축 이연·Task 6.3 안전 분리 `be0d7b2`). 지배적 수리 방향 = 권위를 자기 진술에서 호출자/신뢰 저장소로 이동. 상세: `trail/inbox/2026-08-10~19-*.md`(v2-phase2~6 계열)·`trail/daily/2026-08-13.md`. **미푸시**.
- **완료 (08-19~21): Phase 7 웨이브 1·2·3③-a** (`c85cc62`/`c490ea1`/`58cedbf` — 08-20 사용자 지시 푸시는 `3831f9d` 까지): 선행 결정 4종 확정 + 활성작업 조건화·3축 유예 + 보안 면제 v2 이관 + **증거 발급 배선**(발급 CLI·래퍼 배선·보안 중앙 기록기, 정본 §3.6 리뷰 digest 범위·판정 상태표·유효 증거 3축 — 설계 4회 PASS, 코드 6회차 PASS[사용자 승인 연장 1회]+보안 PASS[Low 2 백로그]). **v2 증거 첫 프로덕션 발급 + 발급→기록→커밋 완주 실증**(게이트 대장 — code_review ✓/보안 축은 스테이징-후-발급 확정 잔존). v2 1672·v1 7종 GREEN. 상세: `trail/inbox/2026-08-21-v2-phase7-wave3a.md` + daily 2026-08-19~20 회전분.
- **완료 (08-22~25): 웨이브 3 ③-b/③-c/③-d + 웨이브 4** — 편집·커밋 게이트 교대(순차 디스패처 + 규율/v2 위임 분리) `b75885b`/`65d8f44`; legacy 표식 3종 청산 → **v2 증거 유일 기록**(판정엔진 legacy 삭제, 제거 완료 4축 충족) `bcd1a91`; 차단로그 마스킹 v2 SSOT `aea94be`/`d38bd49`. v1 7종+v2 1672 GREEN. 상세: `trail/inbox/2026-08-23~25-*.md` + 게이트 대장. (배포 선결 2건[자기무효화·마켓 이름]은 아래 08-27 항목에서 해소/정정.)
- **완료 (08-27): 최행배 페르소나(`7d7e181`) + 게이트 잔재 정리(`eaf14c6`)** — 부산 사투리 승부사 프리셋 추가(내장 프리셋 이름 8곳 복제 전수 동기화 + 크기 상한 준수 압축 1531B), 게이트 잔재 3건(옛 훅 이름 문구 2곳·죽은 가드 제거·커밋게이트 경로 변수 정의+회귀 테스트 T19; 2-a 취소[기존 테스트가 이미 계약 가드]·3번 이월). 각 codex+보안 PASS, 미푸시. 상세 `trail/inbox/2026-08-27-persona-and-gate-residue.md`. **다음 = 배포 안전 2건 또는 래퍼 계약 사이클(codex 타임아웃+종료값)**. 신규 백로그 4건: 대장 후속 항목 절.
- **완료 (08-27): v2 배포 선결 ① 자기무효화 봉합**(`95870df`) — 설치 시 사용자 `.gitignore` 에 rein 런타임 폴더 등록으로 증거원장 untracked 혼입 소멸(실사용자 게이트 자기봉쇄 해소). symlink O_NOFOLLOW 방어·hardlink 는 위협모델 밖(사용자 B안). codex 4R→위협모델 선긋기 사용자 승인 종결+보안 PASS. **②(마켓플레이스 이름)는 blocker 아닌 배포 사이클 편의로 정정.** 다음=v2 배포 본작업(버전 bump·CHANGELOG·main 선별머지·preflight·publish, ② 함께).
- **이전 릴리스·구 완료 (상세는 각 inbox·회전분)**: v1.6.3(07-23 페르소나 선택·커스텀+리뷰 시간상한 워치독, main `9db782c`, 상세 `trail/inbox/2026-07-23-release-v163.md`) / v1.6.2(07-22 리뷰 효율화, main `a7062b0`) / v1.6.1(07-13 증거 블록+index 게이트, main `c5f5c88`) / v1.6.0(07-10 codex 프로필 라우팅, main `b815f85`) / v1.5.8(06-26) / Releases 백필 31개(07-03) / v1.5.x 시리즈(06-09~18) / v1.0.0(04-30 OSS launch).

## 주의사항

- dev/main: 선별 체크아웃 (full merge / 역방향 sync 금지)
- hook 차단 = `exit 2` 또는 `exit 0 + JSON deny` (pre-bash-guard 정책 차단 11지점, Wave 2~)
- DoD: `dod-YYYY-MM-DD-<slug>.md` + `## 라우팅 추천` + `approved_by_user: true` + 단일 `plan ref:` (v1.1.1~)
- plan 편집 시 coverage validator 자동 실행
- lean SessionStart (2026-04-29~): inbox/daily/weekly 자동 주입 안 됨
- codex usage-limit 시 codex-review §4 Sonnet fallback (rein:code-reviewer) — stamp 에 fallback_reason 기재
- main checkout 시 dev tree 가 clean 해야 함 — dirty 면 worktree 격리
