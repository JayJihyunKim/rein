# DoD — 최행배 페르소나 배포본 기본 프리셋 추가

- date: 2026-08-27 착수
- plan ref: 없음 (설계 사이클 불요 — 기존 프리셋 구조에 프롬프트 표면 프리셋 1종 추가, 로직·게이트·엔진 무변경)
- approved_by_user: true (2026-08-27 "4번까지 진행해" — 남은 다음작업 우선순위 정렬 후 페르소나 착수를 명시 승인)

## 범위 연결

plan ref: 없음 (직접 DoD)

근거: `choi-haengbae` 프리셋은 기존 `jennie`/`boss-ace` 와 **동일한 프롬프트 표면 구조**(frontmatter `summary:`/`greeting:` + 캐릭터·언어분기·간결 cap·참고 예시). 유일한 코드 변경은 로더의 **내장 프리셋 등록 집합**(`KNOWN_PERSONA_PRESETS`)에 이름 1개를 더하는 것으로, 해석 로직·게이트·판정 엔진은 불변이다. 나머지는 스킬 안내문·부트스트랩 템플릿·테스트의 내장 프리셋 목록 정합이다. 새 판정 규칙이 없어 plan coverage 매트릭스 대상이 아니다.

## 범위

- `set-n-rest` 에 이미 완성된 최행배 원본을 rein 배포본 **기본 프리셋**으로 승격한다 (모든 `/plugin install` 사용자가 수령).
- 캐릭터: 사용자를 **"행님"** 이라 부르는 부산 사투리 승부사. greeting "행님! 왔습니까. 오늘도 한 판 시원하게 가입시더."
- 불변층(`_invariant.md`)은 **무변경** — 캐릭터는 말투에만, 판단·차단은 냉정 (전 프리셋 공통 불변식).

### 제외

- `rein:persona` 스킬의 런타임 선택 **로직** 변경 없음 — 후보 총수 기반 2단 제시가 3번째 내장 프리셋을 자동 수용한다 (하드코딩된 "내장 2종" 카운트·열거 문구만 3종으로 갱신).
- 페르소나 로더 **해석 로직** 변경 없음 (등록 집합에 이름 1개 추가만 — 이름→경로 resolve·검증·다운그레이드 경로 불변).

## 변경 파일

- `plugins/rein-core/rules/persona/choi-haengbae.md` — 신설 (`jennie`/`boss-ace` 와 스키마 일치, 크기 상한 ≤1536B 준수를 위해 원본 대비 압축 → 1531B)
- `plugins/rein-core/scripts/rein-policy-loader.py` — 내장 프리셋 등록 집합(`KNOWN_PERSONA_PRESETS`)에 `choi-haengbae` 추가 (등록 데이터 1줄; 해석 로직 불변)
- `plugins/rein-core/scripts/rein-persona-lint.py` — 내장 프리셋 집합(`BUILTIN_PRESETS`, 로더와 동기화 계약)에 `choi-haengbae` 추가 (커스텀 이름 충돌 검사 정합)
- `plugins/rein-core/skills/persona/SKILL.md` — 프리셋 선택 메뉴 등재 + "내장 프리셋 2종→3종" 카운트 + 내장 프리셋 열거 지점(fallback 예외·다절 예시·커스텀 이름충돌 고지) 갱신
- `plugins/rein-core/scripts/rein-bootstrap-project.py` — 사용자 프로젝트 persona.yaml 템플릿 주석의 내장 프리셋 언급에 `choi-haengbae` 추가
- 테스트 반영:
  - `tests/scripts/test-persona-preset-greeting.sh` — `choi-haengbae` greeting 검증 추가
  - `tests/hooks/test-session-start-byte-budget.sh` — `choi-haengbae` 주입 예산 루프 + 크기 상한(b2) 검사 추가 (새 최대 프리셋)
  - `tests/scripts/test-persona-lint.sh` — 내장 이름 충돌(L2) 케이스에 `choi-haengbae` 추가
  - `tests/scripts/test-bootstrap-persona-neutral.sh` — 템플릿 주석 grep 에 `choi-haengbae` 추가
  - `tests/skills/test-persona-skill.sh` — "내장 2종" 주석 → 3종

## 검증 기준

- [ ] `choi-haengbae.md` 가 `jennie`/`boss-ace` 와 동일 frontmatter 스키마(`summary:`/`greeting:`) 보유
- [ ] `rein:persona` 선택 흐름에서 3번째 내장 프리셋으로 **도달 가능** (도달 가능성 불변식 — 선택지 상한 때문에 조용히 빠지지 않음)
- [ ] `SKILL.md` 의 "내장 프리셋" 열거·카운트가 **3종**으로 정합 (fallback 진입 예외·커스텀 이름 충돌 고지 포함)
- [ ] 페르소나 관련 테스트 전량 GREEN (loader / session-start inject / byte-budget)
- [ ] 세션 시작 용량 예산 테스트 통과 (프리셋 추가가 주입 바이트 예산을 넘기지 않음)

## 라우팅 추천

- **rein:feature-builder** (프롬프트 표면 프리셋 추가) + **rein:codex-review**
- 보안: 프롬프트 텍스트 추가라 민감도 낮음 — codex-review 후 자동 보안 판정에 맡긴다.

---

approved_by_user: true
