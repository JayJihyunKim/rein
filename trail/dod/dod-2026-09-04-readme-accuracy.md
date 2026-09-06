# DoD — README 두 벌 사실 정정 6건 + 마켓플레이스·플러그인 소개글 (문서)

- date: 2026-09-04 착수
- approved_by_user: true (2026-09-04 "백필해. 그리고 ReadMe나 소개글도 검토한번 해줘" → 검토 보고 후 "응 진행해")
- plan ref: 없음 (문서 정정 — v2.0.3 배포 직후 README 검토 결과)

## 배경

v2.0.3 배포 후 README.md / README.ko.md 를 코드·공개 트리와 대조한 결과 사실과 어긋난 서술 6건이 확인됐다(리뷰 게이트가 테스트를 막는다는 서술, `lean` 프로파일 훅 키 이름 오기, 내장 페르소나 수, `.gitignore` 자동 편집 안 함 주장, 저장소 트리 그림 누락·오기, 공개 저장소에서 깨지는 `AGENTS.md` 링크). 마켓플레이스·플러그인 소개글은 오류는 아니나 너무 짧다.

## 범위

1. README.md / README.ko.md (1:1 parity 유지):
   - "리뷰 전엔 commit·테스트 차단" → 커밋만 차단(테스트 실행은 허용 — TDD).
   - `lean` 이 끄는 훅 키: `post-edit-spec-review-gate`, `post-edit-dod-routing-check` 로 정정(`post-write-*` 오기).
   - 내장 페르소나 2종 → 3종(마르코 / 제니 / 최행배).
   - `.gitignore`: rein 은 자기 런타임 상태 파일 무시 항목만 추가하고(기존 프로젝트도 세션 시작 때 보강) 그 외는 건드리지 않는다고 서술. `trail/`·`.claude/cache/` 무시는 사용자 선택.
   - 저장소 트리: `.rein/policy/persona.yaml`, `.claude/security/profile.yaml` 추가, `.claude/settings.json` 한 줄 핀 줄은 트리에서 제거하고, 활성 기록 위치는 설치 scope 에 따라 Claude Code 가 자기 설정에 남긴다(기본 `user` scope → 저장소 밖 `~/.claude/settings.json`)는 문장으로 대체. Rein 은 거기에 쓰지 않는다.
   - Contributing 의 `AGENTS.md` 링크 → `docs/architecture.md` + `docs/policy-model.md`(공개 저장소에 AGENTS.md 없음).
2. `.claude-plugin/marketplace.json` 플러그인 항목 설명 + `plugins/rein-core/.claude-plugin/plugin.json` `description` 을 README 첫 줄 톤의 한 문장으로.
3. 포함하지 않음: 버전 bump(문서/설명만), 섹션 구조 변경, CHANGELOG 항목(내부 문서 정정은 Rule C 제외 대상).

## 변경 파일

- `README.md`, `README.ko.md`
- `.claude-plugin/marketplace.json`, `plugins/rein-core/.claude-plugin/plugin.json`

## 검증 기준

- [ ] 6건 모두 두 README 에 반영, EN 파일에 한글 잔존 없음(페르소나 표시 이름 제외), 섹션 구조 1:1.
- [ ] README 가 링크하는 경로가 공개 트리에 전부 존재(`AGENTS.md` 링크 0건).
- [ ] `claude plugin validate plugins/rein-core` 통과, `scripts/rein-check-plugin-drift.py` OK, plugin.json version 2.0.3 불변.
- [ ] codex 리뷰 PASS → dev 커밋·푸시 → main 에 문서·매니페스트만 선별 반영 → 공개 미러 반영 확인.

## 라우팅 추천

agent: rein:docs-writer
skills:
  - rein:codex-review
mcps: []
security_tier: base
complexity: low
model_hint: sonnet
effort_hint: low
rationale:
  - 문서·설명 문자열 정정, 코드 동작 변경 없음
approved_by_user: true
