# 2026-06-12 — 게이트 false-negative 4건 수리 (완료, dev 커밋)

## 발단
사용자 요청으로 rein 전체를 보안/구조/신기능 3갈래 병렬 정찰. 보안 정찰이 "게이트 우회" 다수 보고 → 사용자와 위협모델 합의: **"정직한 에이전트 규율"까지**. 적대적/인젝션 우회 하드닝(정책 kill-switch 보호, 도장 content_sha 바인딩, 스탬프 위조 방지)은 **범위 밖으로 보류**(felt-value/포지셔닝 결정). 수리 대상은 "정직한 에이전트인데 게이트가 조용히 미발동(false-negative)"하는 4건으로 한정.

## 수리 (commit 8449114)
- **GMF-1**: 커밋게이트 발동·내부 인식이 단일공백 리터럴(`"git commit"`)이라 `git -C . commit`/더블스페이스/글로벌옵션 형태 미발동. canonical 탐지를 신설 공유 lib `plugins/rein-core/hooks/lib/git-subcommand-model.sh`에 SSOT화(GIT_COMMIT_ERE/GIT_MERGE_ERE + git_clause_invokes), 분류기·dispatcher·게이트내부 3곳이 소비(미러 리터럴 0). shell-token 경계(`\b` 금지)로 `git commit-graph write` 과매칭 차단. 공유 lib 로드 실패 3겹 fail-closed.
- **GMF-2**: merge/rebase/am 면제가 비앵커 substring → 메시지에 "git merge" 든 일반 커밋이 전 검사 skip. 실제 subcommand 파싱으로 교체, 진짜 머지는 면제 유지(dev no-ff 무영향).
- **GMF-3**: DoD 소스 판정이 디렉토리 화이트리스트뿐 → Go internal/pkg/cmd·루트 소스 누락. 소스 확장자 화이트리스트 additive 추가 + generated/vendored/doc/data/lock 제외. tightening-only, 즉시강제, 새 차단 시 파일당 1회 안내(`.ext-source-notice-<sha>`).
- **GMF-4**: 3개 게이트 정책 토글이 `python3` 하드코딩 → 부재 시 127을 "비활성"으로 오인해 fail-open. resolver 뒤로 이동 + rc 구분(rc1=disable, rc0=active, rc-other/인터프리터부재=fail-closed-active).

## 절차/검증
brainstorm(codex-ask Step0 sanity: #1이 2겹임·#3 분류체계·#2 차원분리 적발) → spec(codex 4R PASS) → plan(codex 5R PASS, SSOT를 미러→진짜 단일정의로 승격) → DoD(approved) → parallel-execute 3 웨이브(GMF-1‖GMF-3 → GMF-2 → GMF-4, feature-builder-worker, TDD red 선행) → 부모 웨이브별 델타·테스트 검증 → 통합 codex 코드리뷰 PASS + 보안리뷰 PASS. 5개 스위트 199 테스트 green, 회귀 0. 커밋 자체가 새 게이트 dogfooding 통과.

## 절차 중 발견 (후속 기록감)
- **spec 도장 stale**: plan-writer가 이미 리뷰된 spec의 헤딩을 사후 정규화(`## 4. Scope Items`→`## Scope Items`)해 spec 리뷰 무효화. spec 재리뷰(codex PASS) 후 도장 재생성으로 해소. → cross-role 문서 편집이 리뷰 무효화함을 인지.
- **보안 리뷰어 도장이 content-blind**: `security-reviewer.md`의 도장 생성이 `touch trail/dod/.security-reviewed`뿐 → 어제(v1.5.2) 내용이 그대로 남아 stale. 게이트는 존재만 확인(existence-only)이라 통과되지만 내용은 거짓. 이번엔 수동으로 정확히 정정. **이것 자체가 우리가 고친 게이트-freshness 클래스의 실물** — security-reviewer가 cycle/files/verdict를 실제로 기록하도록 고칠 후보.

## 다음 결정 (사용자 승인 대기)
push(dev) + 버전 bump(hook 동작변경 = user-facing → patch v1.5.3 후보, versioning Rule A) + main 선별 머지 + publish/mirror. 같은날 추가 main 머지는 Rule B 확인 필요(오늘 main 머지 이력 없음).
