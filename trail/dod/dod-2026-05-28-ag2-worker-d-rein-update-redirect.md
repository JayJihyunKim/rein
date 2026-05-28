# DoD — AG-2 worker_d: rein update plugin redirect message

- 날짜: 2026-05-28
- 유형: fix
- Scope ID: ag2-dogfood-worker-d-rein-update-plugin-redirect

## 배경

`tests/scripts/test-rein-update-claude-md-untouched.sh` 의 Assert A 가 FAIL
중. 테스트는 `grep -qiE 'plugin mode|plugin manager'` 로 redirect message
존재를 확인하는데, 현재 `scripts/rein.sh` 의 `merge|update` case 는 한국어
"plugin 모드는 ..." 만 출력해 영문 패턴에 매칭되지 않는다.

## 변경 파일

- scripts/rein.sh

## 작업

1. `scripts/rein.sh` 의 `merge|update` case 에서 출력하는 안내 문구에
   `plugin mode` 또는 `plugin manager` 영문 표현을 포함하도록 수정한다.
2. 기존 한국어 안내는 사용자 경험 유지를 위해 함께 보존한다.
3. CLAUDE.md / `.claude/CLAUDE.md` / manifest 파일은 절대 건드리지 않는다
   (Assert B/C 보장 — 현재 코드 흐름은 echo 후 즉시 exit 0 이므로 manifest
   생성 경로로 진입하지 않음. 유지).

## 완료 기준

- [ ] `bash tests/scripts/test-rein-update-claude-md-untouched.sh` 3/3 PASS
- [ ] `rein update --version` 등 기존 명령 동작 영향 없음 (case branch 한정 수정)
- [ ] scripts/rein.sh 외 파일 편집 0
- [ ] codex review stamp 존재
- [ ] security review stamp 존재 (security_tier:light 면 면제)

## 라우팅 추천

```yaml
agent: feature-builder-worker
skills:
  - rein:codex-review
mcps: []
rationale: |
  단일 파일 (scripts/rein.sh) 의 단일 case 에 영문 표현 추가하는
  trivial fix. worker scope 격리 모드에서 self-stamps 허용.
approved_by_user: true
```
