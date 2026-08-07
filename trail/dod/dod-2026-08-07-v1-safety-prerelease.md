# DoD: v1 안전 소릴리스 — 차단 로그 민감정보 봉합 + 자동 CI + 배포 사전검증

- 날짜: 2026-08-07
- slug: v1-safety-prerelease
- 유형: 버그/보안 수정 + 메인테이너 인프라 (릴리스 번들)
- 입력: `docs/reports/2026-08-05-rein-problem-audit.md` 문제 1(긴급)·문제 2(높음) + v2 설계 문서 §27 (v1 Safety Pre-Release) + 2026-08-07 읽기 전용 정찰
- 사용자 결정 (2026-08-07): ① v2 재구조화 착수 전 안전 조치를 v1 소릴리스로 선행 (감사 보고서의 "게이트 오판 결함 3건"은 v1.6.5 로 기배포 — 본 번들 제외) ② 기존 248KB 추적 로그는 이번에 손대지 않음 — 신규 기록부터 마스킹 적용 (원문 잔존 위험은 문서화로 수용, 후속 결정 가능) ③ 리뷰는 codex 한도 복구(8/10) 전 대체 리뷰어 경로로 즉시 진행.

## 배경

감사 보고서 실증: ① 보안 가드가 차단한 Bash 명령의 **원문 전체**가 git 추적 파일에 영구 기록된다 — 토큰/비밀번호가 인라인 포함된 명령을 차단하는 순간 가드 자신이 비밀값 저장 경로가 된다 (현재 248KB, 393건, 테스트 노이즈 다수 혼입). ② 테스트 30,000줄이 있으나 CI 는 수동 실행 전용 + hooks/scripts 스위트만 실행 — push/PR 회귀 검출 없음. ③ 태그 push 가 사전 검증 없이 배포를 시작한다. ②는 v2 마이그레이션 Phase 0(행위 고정)의 전제 조건이기도 하다.

## 범위

### 1. 차단 로그 민감정보 봉합 (긴급 — 사용자 노출 hook 동작)

`plugins/rein-core/hooks/lib/bash-guard-infra.sh` 의 `log_block()` (호출자: 안전 가드·커밋 게이트·편집 게이트).

- **추적 파일(`trail/incidents/blocks.jsonl`)에 명령 원문 기록 중단.** 구조화 레코드만 기록: `hook`, `reason`, 명령 동사/작업 분류, 마스킹된 대상 표현, `source` (test 여부).
- **마스킹**: 기록 전 token / password / secret / Authorization 헤더 / URL credential(`user:pass@`, `?token=`) / API key 패턴을 `<REDACTED>` 치환. 마스킹 불확실 시 보수적으로 대상 필드 전체 마스킹 (fail-closed).
- **원문은 git 비추적 로컬 로그로 이동**: `.rein/logs/blocks-raw.jsonl` (gitignore 등재 + `git check-ignore` 검증). 단순 크기 상한 회전(마지막 N건 유지).
- **테스트발 이벤트 태깅·집계 제외**: 테스트 하니스 공통 셋업에 env 표식 추가 → `source: test` 기록, 반복 경고 카운트와 incident 집계에서 제외.
- **누적 카운트 산정 개선**: 카운트는 test 제외 레코드만 대상 (기존 전체 파일 재스캔 로직 유지하되 대상 축소).
- **기존 248KB 추적 파일**: 사용자 결정 — **이번 사이클에서 불변** (신규 기록만 마스킹 형식). 원문이 현재 파일·git 히스토리에 잔존하나 public mirror 는 운영 기록 전체 strip 이라 외부 노출 없음 — origin 사설 저장소 한정 위험으로 수용, 이관/재작성은 후속 결정 항목으로 남김.
- legacy `trail/incidents/blocks.log` 도 여전히 기록 중이면 동일 정책 적용.

### 2. 전체 자동 CI (메인테이너 인프라)

`.github/workflows/tests.yml`:

- 트리거 추가: `push` (dev) + `pull_request` (main·dev 대상), `workflow_dispatch` 유지. "수동 실행 전용" 정책 주석은 본 사용자 결정으로 폐기 — 주석 갱신.
- 누락 스위트 추가: `tests/skills/run-all.sh`, `tests/rules/run-all.sh`, `tests/agents/run-all.sh`, `tests/rein-test.sh` (CLI), `tests/integration/` (러너 부재 시 `run-all.sh` 신설), `tests/cli/test-install.sh`.
- `workflow_call` 트리거 추가 — 배포 preflight 가 재사용 (감사 보고서 "reusable workflow" 권고).
- Windows advisory 매트릭스는 현행 유지 (advisory — 릴리스 비차단).

### 3. 배포 사전검증 연결 (메인테이너 인프라)

`.github/workflows/publish-plugin.yml`:

- preflight job 신설: 재사용 테스트 워크플로 호출 + `scripts/rein-check-plugin-drift.py` 실행.
- publish job 에 `needs: preflight` — 사전검증 실패 시 배포 미실행.

### 4. CI 초록 전제 수리 (구현 중 발견 — 기존 실패, 본 변경과 무관함을 HEAD 격리 실행으로 확인)

②를 연결하는 순간 CI 가 빨간불로 시작하면 알람 피로(감사 보고서 문제 6)가 재현되므로, 신규 편입 스위트의 기존 실패를 함께 수리:

- **통합 테스트 fixture 드리프트**: `test-fresh-design-spec-review-no-fallback.sh` 시나리오 3 이 세션 시작 훅의 부트스트랩 표식 계약(v1.2.0~, `.rein/project.json` + `trail/index.md` 요구)을 못 따라와 조기 exit 로 실패 — fixture 에 표식 2개 seed (테스트 전용 수리, 제품 동작 불변).
- **라우팅 맵 바이트 예산 초과**: `routing-map.md` 875B > 800B 상한 (v1.6.3 알려진 백로그). 표·의미 불변, 중복 안내 문구만 압축 → 770B. 관련 스위트(projection·emit·rules·agents) 전량 통과 확인.
- **죽은 설치 테스트 CI 제외**: `tests/cli/test-install.sh` 는 v1.0.1 에서 삭제된 `install.sh` 를 대상으로 하는 사문화 테스트 — CI 편입에서 제외, 파일 삭제 여부는 후속 백로그 (사용자 결정).

### 범위 외

- 감사 보고서 게이트 오판 결함 3건 (v1.6.5 기배포).
- git 히스토리 원문 정화 (파괴적 — 필요 시 별도 결정).
- incident epoch 분리 (해소 후 재발 신규 계산 — 감사 개선안 6번, 후속 백로그).
- mirror workflow 의 preflight 연결 (배포 경로 우선 — 후속).
- `log_block` 전체 파일 재스캔의 성능 재설계 (대상 축소로 완화만 — v2 상태 저장소에서 근본 해소).

## 변경 파일

| 파일 | 변경 |
|---|---|
| `plugins/rein-core/hooks/lib/rein-log-block.py` | 신규 — ① 마스킹·분리 기록·live-only 카운트 SSOT 헬퍼 |
| `plugins/rein-core/hooks/lib/bash-guard-infra.sh` | ① — `log_block()` 이 SSOT 헬퍼 위임 (command 모드), `bg_infra_init` 에 헬퍼 경로 배선 |
| `plugins/rein-core/hooks/pre-edit-dod-gate.sh` | ① — 자체 `log_block()` 도 동일 헬퍼 위임 (path 모드) |
| `plugins/rein-core/scripts/rein-aggregate-incidents.py` | ① — source=test 레코드 incident 집계 제외 |
| `scripts/rein-aggregate-incidents.py` | ① — fallback 본 동기 (drift parity) |
| `.gitignore` | ① — `/.rein/logs/` 비추적 등재 |
| `tests/hooks/lib/test-harness.sh` | ① — `REIN_TEST_MODE=1` export (test 출처 태깅) |
| `tests/hooks/test-bash-guard-log-redaction.sh` | 신규 — ① 행위 기반 검증 10건 |
| `.github/workflows/tests.yml` | ② — push(dev)/PR/workflow_call 트리거 + 전 스위트 + 비용 제어 매트릭스 |
| `tests/integration/run-all.sh` | 신규 — ② 통합 스위트 러너 |
| `.github/workflows/publish-plugin.yml` | ③ — preflight 2job(tests 재사용 + drift) `needs` 배선 |
| `tests/integration/test-fresh-design-spec-review-no-fallback.sh` | ④ — 부트스트랩 표식 fixture 수리 |
| `plugins/rein-core/rules/routing-map.md` | ④ — 바이트 예산 트림 875B→770B (표·의미 불변) |

## 검증 기준

- [ ] 비밀값 패턴이 포함된 명령을 차단해도 추적 파일에 원문·비밀값이 기록되지 않는다 (행위 테스트 — 실제 훅 실행 + 기록 내용 단언).
- [ ] 원문 로그는 git 비추적 경로에만 남는다 (`git check-ignore` 확인 포함).
- [ ] 테스트발 차단이 반복 경고 임계 카운트에 포함되지 않는다.
- [ ] 차단 동작 자체(exit 2 / JSON deny)와 경고 임계 동작 무회귀 — 기존 가드 테스트 전량 통과.
- [ ] CI: dev push 에서 전 스위트가 자동 실행되고 성공한다 (본 번들 커밋의 실제 workflow 실행으로 확인).
- [ ] publish 가 preflight 실패 시 실행되지 않는 구조다 (`needs` 배선 + workflow 구문 검증; 실제 태그 경유 검증은 본 번들 릴리스 태그에서 확인).
- [ ] `bash -n` 통과.
- [ ] 코드 리뷰 + 보안 리뷰 통과 (①은 보안 민감 경로 — 보안 리뷰 필수).

## 라우팅 추천

- agent: 없음 — 메인 세션 직접 구현 (①은 게이트 인접 보안 로깅 경로라 변경 지점을 좁게 유지, ②③은 소규모 workflow 편집이라 병렬 dispatch 이득이 작음. 병렬 평가: ①↔②③ 파일 disjoint 로 병렬 가능하나 ②③ 합산 규모가 작아 순차 채택)
- skills: `rein:codex-review`, `rein:security-reviewer`
- mcps: 없음
- rationale: 직전 사이클(게이트 결함 3건)과 동일 패턴 — 행위 기반 테스트로 새 계약을 먼저 고정 후 구현. codex 사용량 한도 복구는 8/10 — 그 전 진행 시 리뷰 대체 경로(§4 Sonnet fallback, 사유 기재) 사용.

approved_by_user: true
