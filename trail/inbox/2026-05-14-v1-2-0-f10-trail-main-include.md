# v1.2.0 cycle F10 — trail/ main 포함 + public mirror strip

- 날짜: 2026-05-14
- 유형: feat (cycle 잔존 fix, scope 확장)
- 변경 파일: `.claude/rules/branch-strategy.md` (trail/** 처리 정정), `.github/workflows/mirror-to-public.yml` (comment 갱신, strip 로직 유지)

## 배경

v1.2.0 cycle 종결 단계 main 머지 시 plugin install 의 `pre-tool-use-bash-bootstrap-gate.sh` + `pre-edit-trail-bootstrap-gate.sh` 가 main 환경의 trail/ 부재를 "bootstrap 미완료" 로 오인해 모든 Claude 도구 호출 차단. main 의 의도된 design (trail/ 제외) 와 plugin install hook 의 정확한 판단 (trail/ 부재 = bootstrap 안 됨) 이 충돌. 사용자가 "main 포함 + mirror strip" 옵션 승인.

## 변경 내역

### branch-strategy.md
- L85 의 ❌ 제외 표에서 `trail/**` 행 제거 (제외 정책 폐기)
- L94 의 특수 처리 항목 재작성:
  - 이전: "main 제외. v2.0+ plugin-first 구조에서 ... bootstrap 스크립트의 'trail/ 은 사용자 git root 에 속한다' contract 와 충돌"
  - 갱신: "main 포함. 두 layer 의미 (메인테이너 운영 기록 + 사용자 repo 운영 기록). public 노출 차단 = mirror-to-public 이 strip"
  - 이전 정책의 근거 ("plugin marketplace 가 trail/ 끌고 들어감") 가 plugin-first 전환 후 marketplace 가 `plugins/rein-core/` subtree 만 fetch 하도록 정착되면서 무효화됨을 명시

### mirror-to-public.yml
- trail/ strip 로직 자체는 이미 v1.0.x 부터 존재 (defense-in-depth) — 코드 변경 없음
- comment 정정 (F10 contract change 반영):
  - 이전: "Strip trail/ skeleton if it ever lands on main by accident ... if the contract ever changes to legitimately ship trail/ on main, remove this strip step"
  - 갱신: "Strip trail/ from public mirror. v1.2.0 F10 이후 trail/ 는 legitimately ship 됨 (메인테이너 dogfood data). 그러나 public 에는 노출 부적합 — strip 유지 = public-facing boundary"
- duplicated comment block 2개를 1개로 통합 (간결화)

## 영향

- **메인테이너 release path**: 차후 main checkout 시 trail/ 가 dev 에서 가져와짐 → bootstrap-check hook 통과 → release 작업 정상 진행
- **사용자 (plugin install)**: 영향 없음 — plugin tarball 은 `plugins/rein-core/` subtree 만 ship, trail/ 자체가 plugin tarball 에 포함 안 됨
- **public rein repo (git clone)**: 영향 없음 — mirror-to-public 이 trail/ 전체 strip 후 force-push, 메인테이너 운영 기록 외부 노출 차단 유지
- **main tree size**: trail/dod/ + trail/inbox/ + trail/index.md + trail/dod/.codex-reviewed + .security-reviewed 등 누적 시작. 정기 archive 정책 (별 cycle 후속) 필요

## 회귀 차단

- `bash tests/scripts/run-all.sh` 영향 없음 (test 가 trail/ 위치 가정하지 않음)
- mirror-to-public.yml 의 strip 로직 변경 없음 — public mirror 무영향
- branch-strategy.md 는 dev-only (main 제외) — main 머지에 안 들어감

## 다음 단계

- dev commit + push (본 turn)
- main 선별 체크아웃 — dev 의 trail/ 가 함께 가져와짐 → bootstrap-check 통과 → main commit + tag v1.2.0 + push 진행
- 자동 trigger: mirror-to-public (trail/ strip 후 public 전송) + publish-plugin (plugin tarball, trail/ 무관)

## 참고

- 사용자 제안 채택 (2026-05-14 turn 내 의사결정)
- branch-strategy.md 정정 자체는 dev-only — main 머지 대상 아님 (다른 dev-only doc 와 동일)
- mirror-to-public.yml 갱신은 main 머지 대상 (✅ 포함 표의 .github/workflows/* 항목)
- 이전 정책의 회고 (`trail/dod/dod-2026-05-06-trail-skeleton-cleanup.md`) 는 그대로 보존 — 당시 결정의 맥락 기록
