# DoD — B3+B6+B7 stop-session-gate 안정성 묶음

- 날짜: 2026-05-22
- 유형: feat (B3 GC) + fix (B6 portability, B7 ux)
- plan ref: rein-v1.4-improvement-plan.md §5.2 B3/B6/B7 (확정안 §0.5)
- design ref: codex 검증 (2026-05-22) — B3 캐시 경로 정정 + early-exit 앞 배치

## 목표 (Why)

`stop-session-gate.sh` 3건을 한 파일 응집 단위로 처리.
- **B3**: PERF-2 resolver cache (`.rein/cache/hook-resolver/<id>.json`) 는 pre-edit-dod-gate 가 gate check 전에 write 하므로, 차단된 편집은 PostToolUse cleanup 을 못 받아 stale 로 남는다(GC 없음). 24h+ stale entry 를 session stop 시 정리.
- **B6**: line 308 `[[ "$COUNT" =~ ^[0-9]+$ ]]` 는 bash 전용. POSIX `case` 로 교체 (portable.sh 일관성).
- **B7**: line 236 stale DoD 경고가 완료된 DoD(inbox 매칭)도 경고. 완료분 제외.

## 성공 기준 (Acceptance)

1. **B3**: GC 함수 신설 — `.rein/cache/hook-resolver/*.json` 중 mtime 24h 초과만 `rm -f`. **mtime 불명/0 이면 삭제 안 함**(fail-open 삭제 방지). **src-edit early-exit(line 121) 앞**에 호출 — 차단편집 leak(SRC_EDIT_MARKER 미설정)도 회수. best-effort (세션 stop 비차단).
2. **B6**: line 308 을 `case "$COUNT" in *[!0-9]*|'') COUNT=0 ;; esac` 로 교체. 동작 동일 (비정수→0).
3. **B7**: stale 경고 루프(line 236)에서 inbox slug 매칭(완료) DoD 제외. pre-edit-dod-gate.sh:459-471 의 slug 매칭 로직 재사용.
4. **T3**: 완료(inbox-matched) stale DoD 는 경고 미출력, 미완료 stale DoD 는 경고 출력 검증.
5. **B3 test**: 24h 초과 entry 삭제 + 최신 entry 보존 + mtime 불명 시 보존 검증.
6. 기존 stop-gate 테스트(test-session-end-stamp / test-stop-gate-deadlock / test-stop-gate-tone) 전부 PASS.

## 제외 (Out of scope)

- `.rein/cache/hook-output/<id>/` dir GC — rm -rf 재귀 삭제 리스크 회피 위해 제외. aggregator cleanup 이 정상 경로에서 처리. (codex "if needed" → 본 cycle 불필요 판정)
- incident gate / index 검사 로직 변경.
- GC 주기를 cron/SessionEnd 로 옮기는 것 — stop hook 내 best-effort 로 충분.

## 리스크

- (R1) GC 가 활성 entry 를 오삭제. → 24h 임계 + mtime 불명 시 skip 으로 방어. 활성 세션 entry 는 mtime 신선.
- (R2) B7 slug 매칭이 기존 로직과 어긋나면 완료/미완료 오판. → pre-edit-dod-gate 와 동일 sed 패턴 사용 + T3 양방향 검증.
- (R3) GC 가 stop hook 을 느리게/실패시킴. → `|| true` + 디렉토리 부재 즉시 return.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix
skills:
  - rein:codex-review
mcps:
  - serena
rationale: >
  stop-gate 안정성 묶음. B3 는 신규 GC(파일 삭제) 라 fail-open 삭제 방지가 핵심,
  B6/B7 은 동작보존 수정. reproduction-first 로 T3/B3 test 먼저 고정. 캐시 경로/
  early-exit 흐름 추적에 serena 유효. 파일 삭제(rm) 포함이므로 security_tier 는
  standard — security review 로 삭제 경계 점검.
security_tier: standard   # rm -f 파일 삭제 포함 — 삭제 경계 security review 필요
approved_by_user: true    # 사용자 위임 (2026-05-22) — 확정안 §0.5 스코프
```

## Self-review 예정 항목 (AGENTS.md §6)

- GC 가 mtime 불명/신선 entry 를 절대 삭제 안 하는가 (fail-open 방지)
- GC 가 early-exit 앞에서 실행되는가
- B6 POSIX case 가 비정수 방어 동일한가
- B7 이 완료/미완료 양방향 정확한가
- shellcheck clean
