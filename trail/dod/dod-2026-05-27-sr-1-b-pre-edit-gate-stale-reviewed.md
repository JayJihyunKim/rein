# DoD — SR-1.b pre-edit spec gate `.reviewed` orphan stale 백스톱 강화

- 날짜: 2026-05-27
- 유형: fix (security gate hardening — SR-1 잔존 trust boundary 차단)
- plan ref: need-to-confirm.md §SR-1.b (백스톱 (a) 가 `.pending` 존재 전제 — post-edit hook 미발화 시 `.reviewed` 만 잔존하면 통과)

## 목표 (Why)

SR-1 fix 는 두 겹 방어를 도입했다 — (b) post-edit hook 이 spec 편집 시 기존 `.reviewed` 를 `rm -f`, (a) pre-edit gate 가 `.pending`+`.reviewed` 공존 시 freshness 비교. 그러나 (a) 는 `.pending` 존재를 전제로만 동작한다.

만약 post-edit hook 이 발화하지 못하면 (hooks 비활성 / 외부 IDE write / `git checkout` 으로 spec 복원 / MultiEdit JSON 파싱 실패 시 exit 0 silently) 새 `.pending` 이 생성되지 않는다. → 옛 `.reviewed` 만 잔존 → `.pending` 부재라 현재 for 루프 (`pre-edit-dod-gate.sh:404`) 는 실행되지 않음 → spec gate 통과 → 미리뷰 spec 변경분으로 source 편집 허용.

SR-1 이전부터의 trust boundary 라 신규 갭은 아니나, `.reviewed` 도 순회하여 spec 파일 mtime 과 `reviewed=` 타임스탬프를 비교하면 백스톱을 한 겹 더 추가할 수 있다.

## 성공 기준 (Acceptance)

1. **`.reviewed` orphan 백스톱 추가** — `pre-edit-dod-gate.sh` spec gate 가 기존 `.pending` 루프 다음에 `*.reviewed` 도 순회한다. 매칭 `.pending` 이 있으면 skip (기존 분기가 처리). 매칭 `.pending` 부재인 orphan `.reviewed` 만 검사 대상.
2. **freshness 비교 규칙** — 각 orphan `.reviewed` 에 대해:
   - spec 파일 mtime (`stat -c %Y` POSIX-portable, BSD 호환) > `reviewed=` 타임스탬프 (epoch 변환) → stale → 차단 (`UNRESOLVED_SPECS=true`)
   - spec mtime ≤ `reviewed=` → 통과 (정상)
   - spec 파일 미존재 → skip (기존 deleted-spec 처리와 일관)
   - `reviewed=` 필드 누락 / malformed (ISO 8601 shape 위반) → fail-closed (차단)
   - mtime epoch 변환 실패 → fail-closed (차단)
3. **회귀 테스트 (TDD, 실패 → 통과)** — `tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh` 신설:
   - F1 (RED→GREEN): orphan `.reviewed` + spec mtime > `reviewed=` → 차단 (exit 2)
   - F2: orphan `.reviewed` + spec mtime ≤ `reviewed=` → 통과 (exit 0)
   - F3: orphan `.reviewed` + `reviewed=` malformed → fail-closed (exit 2)
   - F4: `*.reviewed` 부재 + `.pending` 부재 → 기존 동작 (통과)
   - F5: 동일 spec 의 `.pending` + `.reviewed` 공존 → SR-1 의 `.pending` 분기가 처리, 신규 분기는 skip (기존 동작 무영향)
4. **기존 테스트 무회귀** — `tests/hooks/test-spec-review-gate.sh` 전량 PASS (특히 SR-1 의 6 fixture 와 `test_gate_allows_reviewed_spec` 무영향).
5. codex 리뷰 PASS + `.codex-reviewed` stamp, security 리뷰 PASS + `.security-reviewed` stamp.

## 변경 파일

- `plugins/rein-core/hooks/pre-edit-dod-gate.sh`
- `tests/hooks/test-pre-edit-dod-gate-sr-1-b.sh` (신설)
- `need-to-confirm.md` (SR-1.b 해결 → `confirmed.md` 이관은 부모 세션이 처리)

## 제외 (Out of scope)

- post-edit hook 미발화 자체의 root cause 처리 — 본 변경은 백스톱(방어 추가)만. hook 발화 보장은 별 cycle (hooks.json 설정 / Claude Code 자체 동작).
- `.pending` 분기 자체 변경 — SR-1 fix 가 충분. orphan `.reviewed` 케이스만 추가.
- spec mtime 비교 정책 자체 — SR-1 이 명시적으로 mtime 을 제외한 이유 (git checkout/touch fragile) 는 `.pending` 분기에 한정. orphan `.reviewed` 는 `.pending` 자체 부재로 content timestamp 비교 불가하므로 mtime 이 유일한 fallback. fragile 이슈는 false-positive 가 아니라 false-negative (touch 후 mtime 이 옛것으로 보일) 위험 — 그래도 현재 갭 (백스톱 0) 보다는 보수적 강화. 이 trade-off 는 본 DoD 의 의도적 선택.
- 다른 need-to-confirm 항목 (PLN-1/AG-2/G3/etc).

## 리스크

- (R1) spec mtime fragility — `git checkout` 가 spec 파일 mtime 을 commit time 이 아닌 checkout time 으로 설정하므로 false-positive (정상 review 후 checkout 으로 mtime > reviewed_at 으로 보임). → R1 mitigation: orphan `.reviewed` 케이스는 본질적으로 비정상 상태 (정상 flow 면 `.pending` 도 같이 있어야 함). orphan 자체가 hook 미발화의 흔적이므로, 안전 측 fail (차단) 선택. 사용자는 spec 을 다시 review 하거나 `.skip-spec-gate` 마커로 emergency bypass.
- (R2) stat 명령 BSD vs GNU 차이 — GNU 는 `stat -c %Y`, BSD 는 `stat -f %m`. → portable.sh 의 패턴 따라 Python `os.path.getmtime` 으로 통일 (PYTHON_RUNNER 이미 resolve 된 상태 이용).
- (R3) `reviewed=` epoch 변환 실패 — locale dependency 우려. → ISO regex shape validation 먼저 + Python `datetime.fromisoformat` 으로 변환 (locale independent). 실패 → fail-closed.
- (R4) 본 세션의 live gate 자기 영향 — 강화 = additive 검증. 기존 정상 flow (`.pending`+`.reviewed` 공존, `.reviewed` 만 있고 spec 미수정) 는 통과 유지. live impact 없음.

## 라우팅 추천

```yaml
agent: rein:feature-builder-fix    # SR-1.b = bugfix (잔존 trust boundary 차단). reproduction-first TDD 적합
skills:
  - rein:codex-review              # commit gate 필수 (.codex-reviewed stamp)
mcps: []
rationale: >
  SR-1 의 잔존 trust boundary 백스톱 추가. reproduction-first TDD 로 F1 (orphan
  `.reviewed` + stale spec) 을 failing test 로 고정 후 pre-edit-dod-gate.sh 의
  spec gate 를 확장. SR-1 패턴 (strict ISO regex + fail-closed + locale-safe
  numeric compare) 을 그대로 재사용해 코드 일관성 유지. security_tier=normal
  — 리뷰 게이트 자체를 만지는 변경이지만 SR-1 의 신규 갭이 아니라 잔존
  boundary 강화 (additive). light 면제는 부적합.
security_tier: normal
approved_by_user: true             # 부모 세션 "남은 백로그 모두 병렬로 각각 진행하자" 위임
```

## Self-review 예정 항목 (AGENTS.md §6)

- 신규 orphan `.reviewed` 분기가 SR-1 의 `.pending`+`.reviewed` 공존 분기와 충돌하지 않는가 (중복 검사 없음)
- spec 파일 미존재 케이스가 기존 `test_gate_ignores_deleted_spec` 와 일관되게 처리되는가
- `stat` portability — Python mtime 으로 통일했는가
- malformed `reviewed=` fail-closed 가 SR-1 패턴과 동일하게 strict ISO regex 인가
- 회귀 5 fixture 가 RED→GREEN 증명 + 기존 27 test 무회귀를 모두 보장하는가
- live gate 자기 영향이 0 인지 (기존 정상 flow 통과 유지)
