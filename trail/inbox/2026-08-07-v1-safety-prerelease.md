# v1 안전 소릴리스 — 차단 로그 민감정보 봉합 + 자동 CI + 배포 preflight

- 날짜: 2026-08-07
- DoD: `trail/dod/dod-2026-08-07-v1-safety-prerelease.md`
- 커밋: dev `3e1213a` (15 files, +678/-70)
- 배경: v2 재구조화(Agent Governance Runtime) 착수 전 감사 보고서(`docs/reports/2026-08-05-rein-problem-audit.md`) 문제 1(긴급)·2(높음) 선행 봉합 — 사용자 확정 순서.

## 완료 내역

1. **차단 로그 민감정보 봉합** (`plugins/rein-core/hooks/lib/rein-log-block.py` 신설 SSOT): 추적 파일(`trail/incidents/blocks.jsonl`)에는 명령 동사+SHA256 12자만, 마스킹 원문은 비추적 `.rein/logs/blocks-raw.jsonl`(1000→500줄 회전). 두 log_block 호출자(bash-guard-infra=command 모드, pre-edit-dod-gate=path 모드) 위임. `REIN_TEST_MODE=1` → source=test 태깅, 반복 경고·incident 집계·세션 종료 advisory 전부 제외 (legacy 무필드=live 취급, FN 방지). aggregate 예시 수집에서 legacy 원문은 `<legacy-target-redacted>` 치환 (신규 클론/worktree 재유출 경로 봉합 — 보안 리뷰 Medium).
2. **자동 CI** (`.github/workflows/tests.yml`): dev push/PR/workflow_call 자동 실행, 7개 스위트(hooks/scripts/skills/rules/agents/CLI/integration) 편입. dev push=ubuntu만, PR/dispatch/태그=macOS 포함(비용 제어 fromJSON 매트릭스). `permissions: contents: read` 명시. `tests/integration/run-all.sh` 신설.
3. **배포 preflight** (`publish-plugin.yml`): preflight 2 job(tests 재사용 + drift check) → publish `needs` 배선.
4. **CI 초록 전제 수리** (기존 실패 — HEAD 격리 재현으로 본 변경 무관 확인): 통합 fixture 부트스트랩 표식 2종 seed, routing-map 875B→770B 압축(표·의미 불변), 죽은 설치 테스트(`tests/cli/test-install.sh`, v1.0.1 삭제된 install.sh 대상) CI 제외.

## 검증·리뷰

- 신규 행위 테스트 13건 (redaction 12 + aggregate T9) + 7개 스위트 전량 GREEN.
- 코드 리뷰: codex 사용량 한도(복구 8/10 09:58)로 **sonnet-fallback 3라운드** — R1 NEEDS-FIX(High 2: 마스킹 `\b` 밑줄 우회로 `GITHUB_TOKEN=` 류 통과, 신규 테스트 러너 미등록) → 수리 → R2 PASS → 보안 후속 3건 델타 R3 PASS. 통과 기록에 대체 리뷰어·사유 명기.
- 보안 리뷰: PASS (2026-08-07T09:57:26Z 재발급). Medium 1(legacy 예시 재유출)·Low 2(advisory 필터, CI 토큰 권한) 즉시 반영, 잔여는 백로그.

## 백로그 (후속, 전부 비차단)

- raw 로그 마스킹 정교화: 과다(`author:` 류 오탐 화이트리스트) + 과소(공백 구분 `--password s3cret`·부착형 `-ps3cret` 패턴 추가) — 묶음 처리 권장.
- 추적 레코드 `#<sha12>` → 로컬 salt HMAC 교체 검토 (약한 비밀 사전공격 확인 채널 차단) 또는 트레이드오프 수용 문서화.
- `rein-aggregate-incidents.py:409` 부근 advisory-summary 독스트링의 `source` 필드 표기를 `hook` 으로 정정 (사전 존재 표기 오류 — 신규 source 태그와 명칭 충돌).
- `tests/cli/test-install.sh` 파일 삭제 여부 — 사용자 결정 대기.
- 기존 248KB `blocks.jsonl` 이관/정화 — 사용자 결정 "이번엔 그대로" (2026-08-07). 후속 결정 시 aggregate legacy 치환이 정화 무력화를 막아줌.
- raw 로그 0600 생성 (Info, 선택 하드닝).
- **릴리스 태그 시 1회 확인**: preflight 로그에서 macOS job 실행 여부 육안 확인 (workflow_call 하 매트릭스 조건 실측).

## 릴리스 상태

dev 커밋까지 완료. 버전 승격(patch, v1.6.6 후보)·main 선별 체크아웃·태그·push·publish 는 **사용자 승인 대기**.
