# DoD: public mirror 에서 publish 워크플로 strip — 공개 저장소 0s 실패 런 근본 수리

- 날짜: 2026-08-08
- slug: mirror-publish-strip
- 유형: 버그 수정 (v1.6.6 릴리스 후속 — 공개 저장소 외관 결함)
- 입력: 2026-08-07 실측 — public rein 에 미러 push 5회마다 0s 실패 런. 원인: 개편된 publish 워크플로가 reusable `tests.yml` 을 참조하는데 미러가 public 에서 `tests.yml` 만 strip → public 의 워크플로 파일이 invalid (없는 파일 참조) → push 마다 실패 런 생성.

## 범위

1. `.github/workflows/mirror-to-public.yml` — strip 목록에 `publish-plugin.yml` 추가 (배포는 rein-dev 전용, public 에 있을 이유 없음). **[적용 완료 — 본 기준서 작성 전 편집분]**
2. `.claude/rules/branch-strategy.md` — publish 워크플로 행에 public strip 방침 명기 (dev 전용 정책 문서).
3. main 반영 (mirror 워크플로는 main 포함 대상) → 미러 재실행으로 public 에서 publish 워크플로 제거 확인 → 이후 push 에 실패 런 미생성 검증.

### 범위 외

- 기존 실패 런 5건의 이력 삭제 (GitHub 이력은 남음 — 신규 발생 차단만).
- public 의 다른 워크플로 정비 (issue-triage 는 정상 유지).

## 변경 파일

| 파일 | 변경 |
|---|---|
| `.github/workflows/mirror-to-public.yml` | strip 목록에 publish-plugin.yml 추가 |
| `.claude/rules/branch-strategy.md` | strip 방침 문서화 (dev 전용) |

## 검증 기준

- [ ] mirror 워크플로 YAML 파싱 통과.
- [ ] main 반영 후 미러 성공 + public `.github/workflows/` 에 publish-plugin.yml 부재.
- [ ] 이후 미러 push 에서 public 실패 런 미생성.
- [ ] 코드 리뷰 통과 (소규모 델타 — 대체 경로, 사유 기재).

## 라우팅 추천

- agent: 없음 — 메인 세션 직접 (2파일 소규모 수리)
- skills: `rein:codex-review` (대체 경로)
- mcps: 없음
- rationale: v1.6.6 릴리스 검증 항목(미러 strip 확인)에서 발견된 후속 결함의 즉시 봉합

approved_by_user: true
