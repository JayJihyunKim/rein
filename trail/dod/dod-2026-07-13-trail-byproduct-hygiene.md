# DoD — trail 부산물 위생: meta-check jsonl 기록 제거 + 런타임 커서 untrack

- date: 2026-07-13
- approved_by_user: true  # 사용자가 AskUserQuestion 으로 "기록 자체를 끄고 삭제" 선택 (2026-07-13 세션)
- source: rein-improve-0713.md 검토 세션 후속 — 사용자 직접 요청 ("trail 정리하면서 남는 불필요한 파일들 안 남도록")

## 범위

1. **meta-check 텔레메트리 제거**: `post-edit-meta-check.sh` 의 무조건 jsonl append(G3-MC-INBOX 단계)를 제거한다. 경고(advisory) 기능은 불변. 근거: 소비자 부재 — repo 전체에서 이 jsonl 을 읽는 production 코드 0건 (집계 산식 검증 테스트 1건뿐, 실데이터 집계 실사용 0회), 20파일 ~420KB 무한 누적.
2. **기존 jsonl 삭제**: `trail/inbox/*-meta-check.jsonl` 20개 git rm.
3. **런타임 커서 untrack**: `trail/incidents/{.last-processed-line,.last-aggregate-state.json,.session-start-line}` 3종을 git 추적 해제(`git rm --cached`) + `.gitignore` 등재. 파일 자체는 유지 (incident 집계 파이프라인의 기능 파일). 근거: 매 세션 자동 변경되는 세션 상태가 커밋 대상이라 working tree 상시 dirty 노이즈 유발.
4. **죽은 파일 삭제**: `trail/incidents/blocks.log.legacy` git rm (레거시, 소비자 없음 확인 필요 — 구현 시 재검증).

### 제외 (유지 결정)

- 감사 로그 유지: `blocks.log`/`blocks.jsonl`(게이트 차단 이력 — 집계·repo-audit 소비), `auto-mode-bypass.log`, `security-surface-exempt.log`, `active-dod-cleanup.log`, `invalid-active-dod-marker.log`, `bad-test-candidates.log`(promotion check 소비) — 규율 증적 또는 실소비자 존재.
- 사용자 repo 에 이미 누적된 jsonl 의 원격 청소는 범위 밖 (CHANGELOG 안내로 갈음).

## 변경 파일

- plugins/rein-core/hooks/post-edit-meta-check.sh
- tests/hooks/test-post-edit-meta-check.sh
- tests/scripts/test-meta-check-inbox-aggregate.sh
- .gitignore
- trail/inbox/2026-05-27-meta-check.jsonl
- trail/inbox/2026-05-28-meta-check.jsonl
- trail/inbox/2026-05-29-meta-check.jsonl
- trail/inbox/2026-05-30-meta-check.jsonl
- trail/inbox/2026-06-01-meta-check.jsonl
- trail/inbox/2026-06-02-meta-check.jsonl
- trail/inbox/2026-06-04-meta-check.jsonl
- trail/inbox/2026-06-05-meta-check.jsonl
- trail/inbox/2026-06-08-meta-check.jsonl
- trail/inbox/2026-06-09-meta-check.jsonl
- trail/inbox/2026-06-11-meta-check.jsonl
- trail/inbox/2026-06-12-meta-check.jsonl
- trail/inbox/2026-06-15-meta-check.jsonl
- trail/inbox/2026-06-16-meta-check.jsonl
- trail/inbox/2026-06-17-meta-check.jsonl
- trail/inbox/2026-06-18-meta-check.jsonl
- trail/inbox/2026-06-26-meta-check.jsonl
- trail/inbox/2026-07-03-meta-check.jsonl
- trail/inbox/2026-07-10-meta-check.jsonl
- trail/incidents/.last-processed-line
- trail/incidents/.last-aggregate-state.json
- trail/incidents/.session-start-line
- trail/incidents/blocks.log.legacy

## 검증 기준

- [ ] 훅 실행 후 `trail/inbox/*-meta-check.jsonl` 이 생성되지 않는다 (기존 테스트의 append 단정을 "파일 미생성" 단정으로 교체, TDD red→green)
- [ ] 경고(advisory) 발화 경로는 기존 테스트 그대로 GREEN (기능 불변)
- [ ] `tests/scripts/test-meta-check-inbox-aggregate.sh` 는 대상 신호 소멸에 따라 제거
- [ ] `git status` 에서 커서 3종이 더 이상 dirty 로 표시되지 않는다 (untrack + ignore 후)
- [ ] incident 집계 스크립트가 커서 파일 부재/신규 생성 시나리오에서 정상 동작 (fresh clone 등가) — 기존 테스트 회귀 GREEN
- [ ] `bash -n` 훅 구문 검증 통과
- [ ] 전체 테스트 스위트 회귀 GREEN

## 라우팅 추천

- 작업 유형: 버그/개선 수정 (소규모, 파일 disjoint 아님 — 순차)
- 1순위: 주 세션 직접 구현 (변경 규모 소·단일 훅 — worker dispatch 오버헤드 불요) + `/codex-review` 게이트 + 보안 리뷰 (훅 편집 = 보안 민감 표면)
- meta_check: auto

approved_by_user: true

## 비고

- 버전 영향: 사용자 repo 에 쓰이는 파일이 달라지므로 user-facing patch. 릴리스는 별도 결정 (Rule B).
- G3 spec 의 해당 단계(G3-MC-INBOX)는 의도적 폐지 — spec 문서는 dev-only 기록이므로 본 DoD 가 폐지 근거 문서 역할.
