# DoD — SPIKE-1 Linux 재측정 prep (Phase 2b 진입 first step)

- 작업 시작일: 2026-05-20
- 유형: research / handover (no bump — production 코드 변경 없음)
- plan ref: docs/plans/2026-05-19-cc-feature-adoption.md (Phase 2 / Task 2.1 — second-pass 측정 prep)

## 범위 연결

plan ref: docs/plans/2026-05-19-cc-feature-adoption.md
work unit: Phase 2 (Task 2.1 follow-up — Linux 환경 second-pass 측정)
covers: [SPIKE-1-verification-spike-measures-parallel-hook-exit2-deny-merge-semantics-and-posttooluse-tool-use-id-presence-and-records-go-no-go-criteria]

본 cycle 은 SPIKE-1 의 측정 환경 caveat ("macOS Darwin 25.4 단일 OS") 해소를 위한 handover 작성 cycle. SPIKE-1 의 go 판정 (HK-4 GO + PERF-2 GO) 은 유지되며, Linux 결과로 보강.

## 배경

SPIKE-1 측정 (2026-05-20) 은 macOS Darwin 25.4 단일 환경에서 진행. report `docs/reports/2026-05-19-cc-feature-spike.md` §5 환경 caveat 의 두 항목:

- 단일 OS (macOS) — Linux 에서 hook entry merge semantics + `tool_use_id` 매칭이 동일한지 미검증
- 단일 Claude Code release — 미래 release 가 평가 모델을 바꿀 가능성 (별 cycle)

사용자 결정 (2026-05-20): Phase 2b 구현 (HK-4 + PERF-2 + HK-5 한 cycle) 진입 **이전** 에 Linux 환경에서 1 cycle 재측정 진행. 사용자가 Docker / native Linux 머신 (실물 또는 VM) 환경 보유.

본 session 은 macOS 이므로 직접 측정 불가 → 사용자가 Linux 환경의 별 Claude Code session 에서 따라할 step-by-step handover 문서를 본 cycle 에 작성. 측정 자체 + 결과 분석은 별 cycle.

## 완료 기준

### handover 문서 작성

- [ ] `trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md` 신축
  - Linux 환경 setup 절차 (Docker / native Linux + Claude Code 설치 / plugin install + 본 repo clone)
  - hooks.json 임시 등록 (spike entry 4개) — macOS cycle 의 등록 diff 를 그대로 재사용
  - 새 Claude Code session 의 첫 Write 로 trigger 발사 (`tests/fixtures/spike/spike-trigger-linux.txt` 신축 또는 macOS 와 동일 trigger 파일 재사용)
  - 3 trigger 후 fixture 분석 (jsonl 12 record = 4 entry × 3 trigger). 추가 4번째 trigger 는 hot-reload 부재 양방향 가설 cross-OS 보강용 **선택** — handover §6.1 의 main path 는 3 trigger
  - hooks.json revert → `git diff --stat plugins/rein-core/hooks/hooks.json` empty 확인
  - 결과 jsonl 일부를 본 repo 의 `docs/reports/2026-05-19-cc-feature-spike.md` 에 §10 (Linux second-pass) 으로 append
  - HK-4 / PERF-2 가 Linux 에서도 동일 판정인지 확인

### handover 의 success criteria 명시

- [ ] HK-4 검증: Linux 의 fixture 에서 `parallel-exit-allow.jsonl` 과 `parallel-exit-deny.jsonl` 모두 3+ record + deny entry 의 `exit 2` 가 system-reminder 로 surface
- [ ] PERF-2 검증: Linux 의 `tool-use-id-pre.jsonl` 과 `tool-use-id-post.jsonl` 의 `tool_use_id` 가 trigger 마다 1:1 매칭
- [ ] OS portability 확인: probe 의 `set -u` + `mktemp` + Python heredoc 이 Linux bash + python3 에서 정상 (별 변경 없이)
- [ ] Linux session 에서도 hooks.json hot-reload 부재가 재현되는지 부산 관찰 (양방향 가설 cross-OS 보강)

### 환경 caveat 처리

- [ ] handover 가 Docker 와 native Linux 모두 cover (Docker 의 경우 Claude Code interactive CLI 의 PTY 요구사항 명시)
- [ ] 측정 후 fixture 가 `tests/fixtures/spike/` 아래에 누적 — gitignore 가 모두 잡으므로 commit 영향 없음 (본 cycle 의 SPIKE-1 commit 에서 `*` + `!.gitignore` 로 변경됨)
- [ ] 결과 report append 시 macOS 결과는 보존 — Linux 결과는 §10 으로 추가 (덮어쓰기 금지)

### 검증

- [ ] codex review PASS (light tier — handover 문서 1개, production 코드 미변경)
- [ ] security review PASS (light tier — handover 가 외부 secret/credential 노출 없음, Docker setup 명령에 hardcoded credential 없음)
- [ ] commit (no bump): `chore(spike): SPIKE-1 Linux 재측정 prep handover`
- [ ] dev push (main 머지 없음 — no bump 작업)

## 비범위

- Linux 환경의 실제 측정 (별 cycle — 사용자가 Linux session 에서 실행)
- 측정 결과 분석 / report §10 작성 (별 cycle — 사용자 measurement 후 본 repo 에 commit 되면 분석 cycle 진입)
- Phase 2b 구현 자체 (HK-4 dispatcher 분할 / PERF-2 cache / HK-5 aggregator — 재측정 완료 후 별 cycle)
- Claude Code release 변동성 — 별 cycle (현 release 의 평가 모델만 측정)
- PERF-3-VERIFY (need-to-confirm.md 등재 — 별 cycle)

## 위험

- **R1**: handover 절차가 사용자 Linux 환경에서 작동 안 함 (Docker PTY / Claude Code install 차이 / plugin marketplace fetch 실패). **Mitigation**: handover 에 troubleshooting 섹션 추가 — Claude Code install 문서 링크 + plugin install dry-run 단계 + 가장 흔한 실패 (PATH / Node version / Plugin marketplace registration) 의 진단 명령.
- **R2**: Linux 에서 결과가 macOS 와 다르면 (예: deny 가 propagate 안 됨, tool_use_id 부재) Phase 2b 의 go 판정이 무효화될 수 있음. **Mitigation**: handover 의 분석 단계에 "Linux 결과가 macOS 와 다르면 SPIKE-1 의 GO 를 PARTIAL-GO 로 hedging" 명시. Phase 2b 진입은 사용자 재결정.
- **R3**: 사용자가 Linux session 에서 측정 후 결과 jsonl 을 commit 안 하고 본 repo 와 sync 되지 않으면 분석 cycle 불가. **Mitigation**: handover 의 마지막 단계에 "결과 jsonl 발췌 + report §10 append 후 commit + push" 단계 명시.

## 라우팅 추천

```yaml
agent: rein:researcher
skills:
  - rein:codex-review        # Step 5 필수 게이트 (handover 본문 + procedure 정확성)
mcps: []
security_tier: light          # production 차단 로직 미변경, secret/auth 무관, handover 문서만 신축
complexity: low               # 1 handover 파일 + 1 DoD
model_hint: sonnet            # 절차 작성, 아키텍처 결정 없음
effort_hint: small            # handover 본문 작성 — 측정 자체는 별 cycle
rationale:
  - 작업 성격: handover prep (production 미변경, 절차 + setup 문서). researcher 가 적합 — 외부 환경 (Linux/Docker) 의 Claude Code 설치/실행 절차 조사 일부 포함 가능
  - 파일 패턴: trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md (신축 1), trail/dod/dod-2026-05-20-cc-feature-spike-1-linux-remeasure-prep.md (신축 1, 본 파일)
  - security_tier light 정당화: handover 가 외부 명령 (docker run / curl / npm install) 을 portray 하지만 credential/secret hardcode 없음. pre-bash-guard 차단 로직 미변경
  - codex-review 단일 스킬: handover 본문의 step 정확성 + Linux 환경 portability claim 의 evidence 검증
  - writing-plans 미포함 이유: 본 작업은 plan 갱신이 아니라 plan Phase 2 의 sub-step prep. Phase 2b 구현 진입 직전 plan-writer cycle 별도 사용
  - changelog-writer 미포함 이유: no bump 작업 — CHANGELOG 변경 없음
approved_by_user: true   # 2026-05-20 사용자 승인 — 사용자 결정 (전체 Phase 2b 한 cycle + 재측정 먼저 + Docker/Linux 머신) 의 first step
```

## 자가 점검 (착수 전)

- [x] trail/index.md 읽음 (SessionStart inject — SPIKE-1 commit 후 갱신된 상태)
- [x] SPIKE-1 cycle commit (`f8e2b79`) dev push 완료 — handover 본 cycle 에서 신축 가능
- [x] 사용자 결정 (2026-05-20) 기록: Phase 2b 한 cycle + 재측정 먼저 + Docker/Linux
- [x] active DoD 갱신 필요 — 본 DoD 가 새 active
- [ ] 라우팅 사용자 승인 받기 (`approved_by_user: true` 로 교체)

## 다음 단계 (라우팅 승인 후)

1. handover 본문 작성 (`trail/inbox/2026-05-20-cc-feature-spike-1-linux-remeasure-handover.md`)
2. codex-review (light tier) — handover 본문 정확성 검증
3. security-review (light tier — advisory)
4. commit (no bump) + dev push
5. trail/inbox 본 cycle 완료 기록 + index.md 의 "다음 진입점" 을 "사용자 Linux 환경에서 handover 실행 대기" 로 갱신
