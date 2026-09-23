# DoD: 죽은 일일 점검 워크플로 제거 — `daily-trail-audit.yml`

- 작성일: 2026-09-23
- plan ref: 없음 — 파일 삭제 1 + 참조 정리 2. 설계·계획 없이 이 기준서의 수용 기준으로 닫는다.
- 사용자 지시: "지우자" (2026-09-23) — 근거 질문 "daily trail audit이 왜 돌아가는거야?" 에 대한 답: 2026-04-16 SOT→trail 리네임 때 들어온 메인테이너용 스케줄(매일 18:00 UTC, main 에서 실행). 읽기 전용 경고 출력만 하고, (a) `find -mtime` 기반 검사는 CI 체크아웃(모든 파일 mtime = now)에서 설계상 작동 불능, (b) index 줄 수 검사는 훅(세션 종료 게이트 5~25줄)이 대체, (c) 출력을 읽는 소비자 없음. 최근 실행 실패는 스크립트가 아니라 GitHub Actions 과금("결제 실패 또는 지출 한도")이며 별개 문제.

## 범위

IN
1. `.github/workflows/daily-trail-audit.yml` 삭제.
2. `.github/workflows/mirror-to-public.yml` 의 해당 strip 블록(`if [ -f .github/workflows/daily-trail-audit.yml ]` 6줄) 제거 — 존재하지 않는 파일을 strip 하는 죽은 코드. 다른 strip 블록(plugin-drift-check·repo-audit·weekly-agent-evolution·tests·govcheck·publish-plugin·self·trail·.rein·AGENTS.md)은 무변경.
3. `.claude/rules/branch-strategy.md` 의 main 포함 표에서 `{repo-audit,daily-trail-audit,weekly-agent-evolution}.yml` 행을 `{repo-audit,weekly-agent-evolution}.yml` 로.

OUT
- `repo-audit.yml`·`weekly-agent-evolution.yml` 등 다른 스케줄 워크플로의 존폐 — 별도 판단.
- 과거 설계·계획·주간 요약·CHANGELOG 의 언급 — 역사 기록, 수정하지 않는다.
- GitHub Actions 과금 문제 — 사용자 계정 설정.
- CHANGELOG — CI 변경은 내부 전용(versioning Rule C 제외 대상), 버전 bump 없음(Rule A "내부 전용").

## Definition of Done

- [ ] 워크플로 파일이 dev 에서 사라지고, 미러 워크플로에 그 파일을 참조하는 줄이 없다
- [ ] 브랜치 규칙 문서의 main 포함 표가 현존 워크플로만 나열한다
- [ ] 미러 워크플로 YAML 구문 유효, 나머지 strip 블록 수 불변
- [ ] 코드 리뷰 + 보안 리뷰(`.github/workflows/**` 는 위험 경로 floor) 통과 → 커밋 → 완료 기록

## 검증 기준

- `git ls-files .github/workflows/daily-trail-audit.yml` → 빈 출력
- `grep -c "daily-trail-audit" .github/workflows/mirror-to-public.yml` → 0
- `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/mirror-to-public.yml'))"` → exit 0 (또는 `ruby -ryaml`/`yq` 등 가용한 파서)
- `grep -c "git rm -q .github/workflows/" .github/workflows/mirror-to-public.yml` → 삭제 전 대비 정확히 1 감소
- `grep -n "daily-trail-audit" .claude/rules/branch-strategy.md` → 빈 출력

## 라우팅 추천

agent: rein:feature-builder-refactor
orchestration: standalone
worker_strategy: 없음 — 파일 3개, 삭제·줄 제거·표 한 칸. 메인 세션 단독 처리
skills:
  - rein:codex-review
mcps: []
security_tier: standard      # .github/workflows/** 위험 경로 — 미러 strip 목록 변경이 공개 노출 범위에 닿는지가 보안 관점
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 동작 불변의 정리(죽은 워크플로·죽은 strip 코드 제거) → refactor 분류. 새 동작 없음
  - 미러 워크플로는 공개 저장소 노출 범위를 결정하므로 보안 리뷰 필수 — strip 목록에서 빠지는 것이 "이미 존재하지 않는 파일" 하나뿐임을 확인
approved_by_user: true  # 사용자 지시 "지우자" (2026-09-23)

## 변경 파일

- .github/workflows/daily-trail-audit.yml (삭제)
- .github/workflows/mirror-to-public.yml
- .claude/rules/branch-strategy.md
- trail/inbox/2026-09-23-remove-daily-trail-audit.md
- trail/index.md
